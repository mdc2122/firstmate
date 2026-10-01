import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
def blk(i, ident, title, state="stalled"):
    return {"id":i,"identifier":ident,"title":title,"status":"blocked","updatedAt":"2026-09-20T00:00:00Z",
            "blockedBy":[{"identifier":"FIR-900","status":"in_progress"}],"blockerAttention":{"state":state},"monitorNextCheckAt":None}
ISSUES=[blk("i13","FIR-13","marker then CEO ack"),blk("i20","FIR-20","marker then ack then engineer ack"),
        blk("i58","FIR-58","past marker then ack"),blk("i57","FIR-57","newer past marker supersedes older future"),
        blk("i134","FIR-134","newer future marker supersedes older past"),blk("i60","FIR-60","one comment: past line then future line"),
        blk("i61","FIR-61","one comment: future line then past line"),blk("i62","FIR-62","future marker buried under 25 acks"),
        blk("i63","FIR-63","malformed marker then ack"),blk("i64","FIR-64","no marker at all")]
# chronological (oldest first); server returns newest first for order=desc
M=lambda t,o="coordinator": f"fm-next-check: {t} owner={o}"
C={
 "i13":["Both blockers healthy.\n\n"+M("2026-10-02T09:00:00Z"),"Acknowledged - CEO"],
 "i20":[M("2026-10-03T00:00:00Z","engineer"),"ack","on it"],
 "i58":[M("2026-10-01T10:00:00Z"),"Acknowledged"],
 "i57":[M("2026-10-05T00:00:00Z"),"ack",M("2026-10-01T11:00:00Z"),"ack"],
 "i134":[M("2026-09-30T00:00:00Z"),"ack",M("2026-10-04T00:00:00Z"),"ack"],
 "i60":["Re-dated.\n"+M("2026-10-01T11:00:00Z")+"\n"+M("2026-10-04T00:00:00Z"),"ack"],
 "i61":["Re-dated.\n"+M("2026-10-04T00:00:00Z")+"\n"+M("2026-10-01T11:00:00Z"),"ack"],
 "i62":[M("2026-10-09T00:00:00Z")]+["ack %d"%n for n in range(25)],
 "i63":["fm-next-check: tomorrow owner=engineer","ack"],
 "i64":["just chatting","ack"],
}
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): sys.stderr.write("REQ %s\n"%self.path)
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(u.query); p=u.path
        if self.headers.get("Authorization")!="Bearer secret-key": return self.send(401,{"error":"auth"})
        if p=="/api/cli-auth/me": return self.send(200,{"companyIds":["co1"]})
        if p=="/api/companies/co1/issues": return self.send(200,ISSUES)
        if p=="/api/companies/co1/approvals": return self.send(200,[])
        if p.startswith("/api/issues/") and p.endswith("/comments"):
            iid=p.split("/")[3]; cs=[{"body":b} for b in C.get(iid,[])]
            if q.get("order",["asc"])[0]=="desc": cs=cs[::-1]
            if "limit" in q: cs=cs[:int(q["limit"][0])]
            return self.send(200,cs)
        self.send(404,{"error":"nf"})
    def send(self,code,obj):
        b=json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
