# A Python mirror of Sources/InStrumCore/Excitement.swift (energy, big moments, tension and drops), run on the same
# performances as Tests/InStrumCoreTests/ExcitementTests.swift so its thresholds were tuned before the Swift existed.
# Run: python3 -I Scripts/excitement-mirror.py
import math, random
class Ex:
    def __init__(s, moments='some', surprises='rare', bad=True, seed=1):
        s.t=0; s.onsets=[]; s.held=set(); s.rate=0; s.e=0; s.lastOn=-1e9; s.lastMoment=-1e9; s.hist=[]; s.pitch=[]; s.phist=[]
        s.tension=0; s.drop=0; s.pending=None; s.moments=moments; s.events=[]; s.bad=bad
    def th(s): return 0.78 if s.moments=='some' else 0.65
    def cd(s): return 6.0 if s.moments=='some' else 2.5
    def fire(s, kind, strength, low):
        isDrop = s.bad and s.tension>0.6
        if isDrop: s.tension=0; s.drop=1
        s.pending=(kind,strength,low,isDrop); s.lastMoment=s.t; s.events.append((s.t,kind,round(strength,2),low,isDrop))
    def on(s, n, v):
        s.onsets.append((s.t,n,v)); s.held.add(n); s.rate+=1/0.5; s.lastOn=s.t; s.pitch.append(n); s.pitch=s.pitch[-8:]
        if s.moments=='off': return
        rec=[o for o in s.onsets if s.t-o[0]<=0.040+1e-9]
        if len(rec)>=3:
            mv=sum(o[2] for o in rec)/len(rec)
            if mv>=s.th() and s.t-s.lastMoment>=s.cd():
                s.fire('chord', max(0.3,(mv-s.th())/(1-s.th())), sum(o[1] for o in rec)/len(rec)<48)
    def off(s,n): s.held.discard(n)
    def step(s, dt):
        s.t+=dt; s.rate*=math.exp(-dt/0.5); s.onsets=[o for o in s.onsets if s.t-o[0]<=2.0]
        vbar=sum(o[2] for o in s.onsets)/len(s.onsets) if s.onsets else 0
        size=min(1,max(0,(len(s.held)-1)/7)); raw=0.45*vbar+0.35*min(1,s.rate/8)+0.2*size
        if s.t-s.lastOn>=3: raw=0
        tau=0.25 if raw>s.e else 4.0; s.e+=(1-math.exp(-dt/tau))*(raw-s.e)
        if s.e<1e-4: s.e=0
        s.hist.append((s.t,s.e)); s.hist=[h for h in s.hist if s.t-h[0]<=3.0]
        if s.moments!='off' and s.e>=0.75 and s.e-min(h[1] for h in s.hist)>=0.35 and s.t-s.lastMoment>=s.cd(): s.fire('crescendo', s.e, False)
        pm=sum(s.pitch)/len(s.pitch) if s.pitch else 0; s.phist.append((s.t,pm)); s.phist=[h for h in s.phist if s.t-h[0]<=2.0]
        old=[h for h in s.hist if s.t-h[0]>=0.9]; slope=(s.e-old[-1][1])/1.0 if old else 0
        climbing = len(s.phist)>1 and s.t-s.phist[0][0]>=1.0 and s.t-s.lastOn<0.5 and pm-s.phist[0][1]>4
        if s.bad and (climbing or slope>0.05): s.tension=min(1,s.tension+0.35*dt)
        else: s.tension=max(0,s.tension-0.08*dt)
        s.drop=max(0,s.drop-dt/2.5)
def run(ex, notes, until, dt=1/60):
    notes=sorted(notes); i=0; log=[]
    while ex.t<until:
        while i<len(notes) and notes[i][0]<=ex.t+1e-9:
            t,kind,n,v=notes[i]; (ex.on(n,v) if kind=='on' else ex.off(n)); i+=1
        ex.step(dt); log.append((ex.t,ex.e,ex.tension))
    return log
def at(log,t): return min(log,key=lambda x:abs(x[0]-t))
# 1 energy: fff sixteenths for 2 s (each 0.1 s long), then silence
ex=Ex(); ns=[]
for k in range(16): ns+=[(k*0.125,'on',60,1.0),(k*0.125+0.1,'off',60,0)]
log=run(ex,ns,12)
print('energy@0.6', round(at(log,0.6)[1],3), '@1.5',round(at(log,1.5)[1],3), '@2', round(at(log,2.0)[1],3), 'max', round(max(l[1] for l in log),3), '@12', round(at(log,12)[1],3), 'events', ex.events)
# 2 hard chord
ex=Ex(); run(ex,[(0,'on',40,0.9),(0.01,'on',45,0.9),(0.02,'on',52,0.9),(0.03,'on',36,0.9)],1); print('hard chord', ex.events)
# 3 cooldown: fff chords at 8/s for 10 s
for m in ['some','lots']:
    ex=Ex(moments=m); ns=[]
    for k in range(80):
        for n in [48,52,55,60]: ns+=[(k*0.125,'on',n,1.0),(k*0.125+0.1,'off',n,0)]
    run(ex,ns,10); print('cooldown',m,len(ex.events),[e[:2] for e in ex.events])
# 4 crescendo: soft single notes 4/s for 4 s, then fff sixteenths
ex=Ex(); ns=[]
for k in range(16): ns+=[(k*0.25,'on',60+(k%3),0.3),(k*0.25+0.2,'off',60+(k%3),0)]
for k in range(24): ns+=[(4+k*0.125,'on',62+(k%3),1.0),(4+k*0.125+0.1,'off',62+(k%3),0)]
log=run(ex,ns,8); print('crescendo', ex.events, 'energy@4',round(at(log,4)[1],2),'@5.5',round(at(log,5.5)[1],2))
# 5 drop: climbing pitch for 4 s at mf, then a hard chord
ex=Ex(); ns=[]
for k in range(40):
    n=48+k; ns+=[(k*0.125,'on',n,0.6),(k*0.125+0.1,'off',n,0)]
ns+=[(5.2,'on',60,0.95),(5.21,'on',64,0.95),(5.22,'on',67,0.95)]
log=run(ex,ns,8); print('drop', ex.events, 'tension@5', round(at(log,5.1)[2],2))
# 6 moment with low tension is not a drop
ex=Ex(); run(ex,[(0,'on',60,0.95),(0.01,'on',64,0.95),(0.02,'on',67,0.95)],1); print('no-drop', ex.events)
