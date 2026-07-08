import type { FastifyInstance } from 'fastify';

// Lecteur de validation dev (Phase 2) — le vrai client web arrive en Phase 4.
// <audio> utilise nativement les requêtes Range : seek instantané sans téléchargement complet.
const PAGE = `<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HomeSpotify — lecteur dev</title>
<style>
body{font-family:system-ui;max-width:640px;margin:2rem auto;padding:0 1rem;background:#111;color:#eee}
li{display:flex;align-items:center;gap:.6rem;padding:.45rem 0;border-bottom:1px solid #2a2a2a;list-style:none;cursor:pointer}
li:hover{color:#1db954}img{width:40px;height:40px;object-fit:cover;border-radius:4px;background:#333}
.q{margin-left:auto;font-size:.72rem;color:#888}audio{width:100%;margin-top:1rem}ul{padding:0}
</style></head><body>
<h1>HomeSpotify <small style="font-size:.5em;color:#888">lecteur dev — Phase 2</small></h1>
<audio id="player" controls preload="none"></audio>
<ul id="list"></ul>
<script>
const fmt=s=>s?Math.floor(s/60)+":"+String(Math.round(s%60)).padStart(2,"0"):"?";
fetch("/api/tracks?limit=200").then(r=>r.json()).then(({items})=>{
  const ul=document.getElementById("list");
  for(const t of items){
    const li=document.createElement("li");
    const img=document.createElement("img");
    if(t.hasCover)img.src="/api/tracks/"+t.id+"/cover";
    const label=document.createElement("span");
    label.textContent=t.artist+" — "+t.title+" ("+fmt(t.durationSeconds)+")";
    const q=document.createElement("span");q.className="q";
    q.textContent=t.quality?t.quality.sampleRate/1000+" kHz / "+t.quality.bitDepth+" bit / "+t.quality.status:"?";
    li.append(img,label,q);
    li.onclick=()=>{const p=document.getElementById("player");p.src="/api/tracks/"+t.id+"/stream";p.play();};
    ul.append(li);
  }
});
</script></body></html>`;

export function registerPlayerRoute(app: FastifyInstance): void {
  app.get('/player', async (_request, reply) => reply.type('text/html; charset=utf-8').send(PAGE));
}
