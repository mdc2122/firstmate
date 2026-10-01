# Minimal Paperclip board API emulator over real HTTP; serves JSON from board/.
import http.server, json, os, sys, time, re
D = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a): open(os.path.join(D, "access.log"), "a").write(self.requestline + "\n")
    def send(self, code, body):
        b = body.encode(); self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer test-key": return self.send(401, '{"error":"unauthorized"}')
        p = self.path
        if p.startswith("/api/companies/co1/issues?"): return self.send(200, open(os.path.join(D,"issues.json")).read())
        if p.startswith("/api/companies/co1/approvals?"): return self.send(200, "[]")
        m = re.match(r"/api/issues/([^/?]+)/comments\?", p)
        if m:
            if os.path.exists(os.path.join(D, "hang")): time.sleep(30)
            f = os.path.join(D, "comments-%s.json" % m.group(1))
            return self.send(200, open(f).read() if os.path.exists(f) else "[]")
        self.send(404, '{"error":"not found"}')
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
