import json,sys,re
def norm(v):
    if isinstance(v,dict): return {k:norm(x) for k,x in v.items()}
    if isinstance(v,list): return [norm(x) for x in v]
    if isinstance(v,str) and v.startswith('Error:'): return v.split('\n')[0]
    return v
a=norm(json.load(open(sys.argv[1]))); b=norm(json.load(open(sys.argv[2])))
known=set(sys.argv[3].split(',')) if len(sys.argv)>3 else set()
same=True
for k in a:
    if a[k]!=b.get(k):
        tag='EXPECTED-DIFF' if k in known else 'DIFF'
        if k not in known: same=False
        print(tag, k); print(' base:', json.dumps(a[k])[:800]); print(' new :', json.dumps(b.get(k))[:800])
print('NO UNEXPECTED DIFFERENCES' if same else 'UNEXPECTED DIFFERENCES FOUND', len(a), 'scenarios')
