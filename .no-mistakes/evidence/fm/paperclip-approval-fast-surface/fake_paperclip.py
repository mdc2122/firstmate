import http.server, json, os, sys
D=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): open(os.path.join(D,'requests.log'),'a').write(self.command+' '+self.path+'\n')
    def do_GET(self):
        if self.headers.get('Authorization')!='Bearer test-key':
            self.send_response(401); self.end_headers(); self.wfile.write(b'denied'); return
        p=self.path
        if p.startswith('/api/cli-auth/me'): f='me.json'
        elif p.startswith('/api/companies/co1/issues?'): f='issues.json'
        elif p.startswith('/api/companies/co1/approvals?'): f='approvals.json'
        elif '/comments' in p: body=b'[]'; f=None
        else:
            self.send_response(404); self.end_headers(); return
        if f: body=open(os.path.join(D,f),'rb').read()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
