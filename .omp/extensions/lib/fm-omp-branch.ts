import { lstatSync, readFileSync } from "node:fs";

// Shared by the omp watcher and the omp supervision-branch extension
// (docs/supervision-protocols/omp.md, docs/pi-supervision-branch.md "omp").

// The TypeScript reader of config/omp-supervision-branch. docs/configuration.md
// "omp supervision branch" owns the format and bin/fm-lease-lib.sh's
// fm_omp_branch_mode is the bash reader: the first whitespace-separated word
// selects `on` or `report-only`; anything else - an absent, unreadable,
// symlinked, or unknown file - is `off`, which leaves every omp extension on
// its pre-branch behavior.
export type OmpBranchMode = "on" | "report-only" | "off";

export function readOmpBranchMode(configDir: string): OmpBranchMode {
  const file = `${configDir}/omp-supervision-branch`;
  try {
    if (!lstatSync(file).isFile()) return "off";
    const word = readFileSync(file, "utf8").trim().split(/\s+/, 1)[0] ?? "";
    return word === "on" || word === "report-only" ? word : "off";
  } catch {
    return "off";
  }
}

// Report-only handoff from the omp watcher to the branch, carried over
// pi.events like the Pi dispatch offer (lib/fm-branch-dispatch.ts) but with no
// accept step: the watcher has already delivered the same wake to main and
// never waits on the shadow. `rows` are the raw durable-queue lines the
// branch would have been granted, `tasks` the task ids they resolve to.
export const FM_OMP_BRANCH_SHADOW_EVENT = "fm-omp-branch-supervision:shadow";

export type OmpBranchShadowWake = {
  message: string;
  heartbeat: boolean;
  rows: string[];
  tasks: string[];
};

// Report-only mode runs the branch as a shadow: it sees every wake it would
// have been offered and records what it would do, while main keeps handling the
// wake exactly as before. Its shell may only run commands this classifier
// proves read-only; everything else is refused before a shell starts and the
// refusal is recorded as an action the branch would have taken.
//
// The rule is an allowlist over a deliberately small grammar: plain words,
// quoting, pipes, and the sequencing operators. Anything that can hide a
// second command or write a file - command or process substitution, a
// redirection other than to /dev/null or between descriptors, a background
// operator, a program that can run another program (find -exec, xargs, sed's
// e and w commands, awk's system), or an unlisted program - refuses. Like the
// lease guards, this is confused-agent-grade containment (bin/fm-lease-lib.sh).
// `cd` only moves the branch's own one-shot subshell (each command runs in a
// fresh `bash -c`), so it changes nothing outside the command it prefixes.
const READ_ONLY_PROGRAMS: Record<string, true> = {
  cat: true, head: true, tail: true, grep: true, egrep: true, rg: true, ls: true, wc: true,
  jq: true, date: true, echo: true, printf: true, stat: true, basename: true, dirname: true,
  sort: true, cut: true, tr: true, true: true, false: true, test: true, "[": true,
  pwd: true, realpath: true, readlink: true, column: true, nl: true, comm: true, diff: true,
  cd: true,
};

// Firstmate commands whose whole surface reads state, and the read verbs of
// the mixed ones. bin/fm-crew-state.sh, bin/fm-peek.sh, and bin/fm-pr-state.sh
// write nothing under the home.
const READ_ONLY_FIRSTMATE: Record<string, true | readonly string[]> = {
  "fm-crew-state.sh": true,
  "fm-peek.sh": true,
  "fm-pr-state.sh": true,
  "fm-lease.sh": ["check"],
  "fm-branch-outcome.sh": ["list"],
  "fm-tasks-axi.sh": ["list", "show", "ready"],
};

export function readOnlyCommandRefusal(command: string): string {
  if (/[`]|\$\(|<\(|>\(/.test(command)) return "command or process substitution";
  // Drop the redirections that cannot write a file before looking for any
  // other redirection.
  const stripped = command.replace(/[0-9]?>>?\s*\/dev\/null|[0-9]?>&[0-9]|<\s*\/dev\/null/g, " ");
  if (/[<>]/.test(stripped.replace(/'[^']*'|"[^"]*"/g, ""))) return "file redirection";
  if (/(^|[^&])&($|[^&])/.test(stripped.replace(/'[^']*'|"[^"]*"/g, ""))) return "background operator";
  const segments = stripped
    .replace(/'[^']*'|"[^"]*"/g, (quoted) => quoted.replace(/[|;&\n]/g, " "))
    .split(/\|\||&&|[|;\n]/)
    .map((segment) => segment.trim())
    .filter(Boolean);
  for (const segment of segments) {
    const words = segment.split(/\s+/).filter((word) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(word));
    const program = (words[0] ?? "").replace(/^['"]|['"]$/g, "");
    if (!program) continue;
    const base = program.split("/").pop() ?? program;
    // sed is read-only only as a printing filter: no in-place edit, and no
    // script that could write a file or run a command.
    if (base === "sed") {
      if (words.some((word) => /^-[a-zA-Z]*i/.test(word) || word.startsWith("--in-place"))) return "sed in-place edit";
      if (words.slice(1).some((word) => !word.startsWith("-") && /[ewW]/.test(word.replace(/^['"]|['"]$/g, "").replace(/\/[^/]*\//g, "")))) {
        return "sed script that can write or execute";
      }
      if (program === base) continue;
    }
    if (base === "sort" && words.some((word) => /^-[a-zA-Z]*o/.test(word) || word.startsWith("--output"))) return "sort writing a file";
    if (READ_ONLY_PROGRAMS[base] === true && program === base) continue;
    const firstmate = /(^|\/)bin\/fm-[a-z-]+\.sh$/.test(program) ? READ_ONLY_FIRSTMATE[base] : undefined;
    if (firstmate === true) continue;
    if (firstmate && firstmate.includes(words[1] ?? "")) continue;
    return `${program}${words[1] ? ` ${words[1]}` : ""} is not a read-only command`;
  }
  return "";
}
