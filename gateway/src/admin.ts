export const modernAdminHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Peak AI NPC · Control</title>
  <style>
    :root{color-scheme:dark;font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;--bg:#0b0d0c;--surface:#111411;--raised:#171b17;--line:#293029;--ink:#f4f5f1;--muted:#969d94;--accent:#b8ff65;--danger:#ff7770}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink)}button,input,textarea{font:inherit}button{cursor:pointer}
    .shell{min-height:100vh;display:grid;grid-template-columns:230px 1fr}.rail{position:sticky;top:0;height:100vh;padding:26px 18px;border-right:1px solid var(--line);background:#0e110f}
    .brand{display:flex;align-items:center;gap:10px;margin:0 8px 30px;font-weight:750;letter-spacing:-.03em}.mark{width:10px;height:10px;border-radius:50%;background:var(--accent);box-shadow:0 0 18px #b8ff6588}
    nav{display:grid;gap:4px}nav button{border:0;border-radius:9px;background:transparent;color:var(--muted);padding:10px 12px;text-align:left}nav button.active,nav button:hover{background:var(--raised);color:var(--ink)}
    .rail small{position:absolute;left:26px;bottom:24px;color:#686f67}.workspace{min-width:0;padding:28px 34px 56px}.topbar{display:flex;align-items:center;gap:12px;margin-bottom:34px}.topbar h1{margin:0 auto 0 0;font-size:25px;letter-spacing:-.04em}
    .status-dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}.status-dot.ok{background:var(--accent);box-shadow:0 0 12px #b8ff6577}.global-notice{color:var(--danger);font-size:12px}
    input,textarea{width:100%;border:1px solid var(--line);border-radius:9px;outline:none;background:#0e110f;color:var(--ink);padding:9px 10px}input:focus,textarea:focus{border-color:#607c43}
    .secret{width:230px}.button{border:1px solid var(--line);border-radius:9px;background:var(--raised);color:var(--ink);padding:9px 12px;font-weight:650}.button.primary{border-color:var(--accent);background:var(--accent);color:#17200f}.button.danger{color:var(--danger)}.button:disabled{opacity:.45;cursor:not-allowed}
    .view[hidden]{display:none}.section-head{display:flex;align-items:end;justify-content:space-between;gap:20px;margin-bottom:20px}.section-head h2{margin:0 0 4px;font-size:20px;letter-spacing:-.025em}.section-head p{margin:0;color:var(--muted);font-size:13px}
    .metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));border-top:1px solid var(--line);border-bottom:1px solid var(--line);margin-bottom:28px}.metric{padding:18px 16px}.metric+ .metric{border-left:1px solid var(--line)}.metric span{display:block;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em}.metric strong{display:block;margin-top:7px;font-size:20px;font-weight:680}
    .block{margin-top:28px}.block h3{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0 0 10px}
    table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:11px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{color:var(--muted);font-size:10px;text-transform:uppercase;letter-spacing:.08em;font-weight:650}td.empty{color:var(--muted);padding:24px 10px}
    .studio{display:grid;grid-template-columns:230px minmax(0,1fr);min-height:620px;border-top:1px solid var(--line)}.npc-list{border-right:1px solid var(--line);padding:14px 14px 0 0}.npc-list button{display:block;width:100%;border:0;border-radius:8px;background:transparent;color:var(--muted);padding:10px;text-align:left}.npc-list button.active,.npc-list button:hover{background:var(--raised);color:var(--ink)}
    .editor{padding:20px 0 0 24px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.grid.four{grid-template-columns:repeat(4,minmax(0,1fr))}.field{display:grid;gap:6px}.field.full{grid-column:1/-1}.field label{color:var(--muted);font-size:11px}.field textarea{min-height:100px;resize:vertical}.toggle{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:12px}.toggle input{width:auto}
    .editor-actions{display:flex;justify-content:space-between;gap:10px;margin-top:18px;padding-top:16px;border-top:1px solid var(--line)}.actions{display:flex;gap:8px}.notice{min-height:20px;margin:12px 0 0;color:var(--muted);font-size:12px}.notice.error{color:var(--danger)}
    .privacy{display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:34px}.policy{border-left:1px solid var(--line);padding-left:24px}.policy dl{margin:0}.policy div{padding:10px 0;border-bottom:1px solid var(--line)}dt{color:var(--muted);font-size:11px}dd{margin:5px 0 0}
    @media(max-width:900px){.shell{grid-template-columns:1fr}.rail{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line)}.rail small{display:none}nav{grid-template-columns:repeat(4,1fr)}.workspace{padding:22px 18px 40px}.topbar{flex-wrap:wrap}.secret{width:100%}.metrics{grid-template-columns:repeat(2,1fr)}.metric:nth-child(3){border-left:0}.studio,.privacy{grid-template-columns:1fr}.npc-list{border-right:0;border-bottom:1px solid var(--line)}.editor{padding-left:0}.grid.four{grid-template-columns:repeat(2,1fr)}.policy{border-left:0;padding-left:0}}
  </style>
</head>
<body>
  <div class="shell">
    <aside class="rail">
      <div class="brand"><span class="mark"></span>Peak AI NPC</div>
      <nav aria-label="Dashboard">
        <button class="active" data-view="overview">Overview</button>
        <button data-view="npcs">NPC studio</button>
        <button data-view="residents">Residents</button>
        <button data-view="conversations">Conversations</button>
        <button data-view="privacy">Privacy</button>
      </nav>
      <small>Gateway 1.0.0</small>
    </aside>
    <main class="workspace">
      <header class="topbar">
        <span id="healthDot" class="status-dot"></span>
        <h1 id="viewTitle">Overview</h1>
        <span id="globalNotice" class="global-notice"></span>
        <input id="secret" class="secret" type="password" autocomplete="off" placeholder="Gateway secret">
        <input id="serverId" class="secret" value="local" aria-label="Server ID">
        <button id="refresh" class="button">Refresh</button>
      </header>

      <section id="overview" class="view">
        <div class="section-head"><div><h2>Runtime</h2><p>Provider health, active servers, and bounded usage.</p></div></div>
        <div class="metrics">
          <div class="metric"><span>Text</span><strong id="mText">—</strong></div>
          <div class="metric"><span>Speech</span><strong id="mSpeech">—</strong></div>
          <div class="metric"><span>Transcription</span><strong id="mStt">—</strong></div>
          <div class="metric"><span>Memory</span><strong id="mMemory">—</strong></div>
        </div>
        <div class="block"><h3>Registered servers</h3><table><thead><tr><th>Server</th><th>Version</th><th>Last seen</th></tr></thead><tbody id="serverRows"></tbody></table></div>
        <div class="block"><h3>Usage</h3><table><thead><tr><th>Server</th><th>Requests</th><th>Tokens in/out</th><th>Failures</th><th>Avg latency</th></tr></thead><tbody id="usageRows"></tbody></table></div>
      </section>

      <section id="residents" class="view" hidden>
        <div class="section-head"><div><h2>Persistent residents</h2><p>Inspect identity, routine, mood, lifecycle, and simulation capacity.</p></div><div class="actions"><input id="residentSearch" placeholder="Search residents"><button id="simulateResidents" class="button">Run simulation tick</button></div></div>
        <div class="block"><p id="residentStats" class="notice"></p><table><thead><tr><th>Name</th><th>Occupation</th><th>Status</th><th>Activity</th><th>Mood</th><th>Last seen</th><th>Controls</th></tr></thead><tbody id="residentRows"></tbody></table></div>
      </section>

      <section id="npcs" class="view" hidden>
        <div class="section-head"><div><h2>NPC studio</h2><p>Identity, prompts, voice, access, and tool permissions without Lua edits.</p></div><button id="newNpc" class="button">New NPC</button></div>
        <div class="studio">
          <div id="npcList" class="npc-list"></div>
          <form id="npcForm" class="editor">
            <div class="grid">
              <div class="field"><label for="npcId">NPC ID</label><input id="npcId" required pattern="[A-Za-z0-9_-]{1,64}"></div>
              <div class="field"><label for="model">Ped model</label><input id="model" required></div>
              <div class="field"><label for="npcName">Name</label><input id="npcName" required></div>
              <div class="field"><label for="occupation">Occupation</label><input id="occupation" required></div>
            </div>
            <div class="grid four" style="margin-top:14px">
              <div class="field"><label for="coordX">X</label><input id="coordX" type="number" step="any" required></div>
              <div class="field"><label for="coordY">Y</label><input id="coordY" type="number" step="any" required></div>
              <div class="field"><label for="coordZ">Z</label><input id="coordZ" type="number" step="any" required></div>
              <div class="field"><label for="coordW">Heading</label><input id="coordW" type="number" step="any" required></div>
            </div>
            <div class="grid" style="margin-top:14px">
              <div class="field full"><label for="personality">Personality prompt</label><textarea id="personality"></textarea></div>
              <div class="field full"><label for="knowledge">Knowledge boundary</label><textarea id="knowledge"></textarea></div>
              <div class="field"><label for="voiceId">Voice ID</label><input id="voiceId"></div>
              <div class="field"><label for="voiceLanguage">Voice language</label><input id="voiceLanguage" placeholder="en"></div>
              <div class="field full"><label for="tools">Allowed tools · comma separated</label><input id="tools"></div>
              <div class="field"><label for="distance">Interaction distance</label><input id="distance" type="number" min="1" max="20" step=".1" value="3"></div>
              <label class="toggle"><input id="enabled" type="checkbox" checked>Interaction enabled</label>
            </div>
            <div class="editor-actions">
              <button id="deleteNpc" class="button danger" type="button">Delete</button>
              <div class="actions"><button id="reloadNpc" class="button" type="button">Reset</button><button class="button primary" type="submit">Save NPC</button></div>
            </div>
            <p id="npcNotice" class="notice" aria-live="polite"></p>
          </form>
        </div>
      </section>

      <section id="conversations" class="view" hidden>
        <div class="section-head"><div><h2>Conversations</h2><p>Bounded operational metadata; transcript capture is off unless explicitly enabled.</p></div></div>
        <table><thead><tr><th>Time</th><th>NPC</th><th>Session</th><th>Provider</th><th>Latency</th><th>Result</th></tr></thead><tbody id="conversationRows"></tbody></table>
      </section>

      <section id="privacy" class="view" hidden>
        <div class="section-head"><div><h2>Privacy & retention</h2><p>Inspect effective limits and erase one scoped NPC relationship.</p></div></div>
        <div class="privacy">
          <form id="forgetForm">
            <div class="grid">
              <div class="field"><label for="forgetNpc">NPC ID</label><input id="forgetNpc" required></div>
              <div class="field"><label for="characterId">Character ID</label><input id="characterId" required></div>
            </div>
            <div class="actions" style="margin-top:14px"><button class="button danger" type="submit">Delete scoped memory</button></div>
            <p id="privacyNotice" class="notice" aria-live="polite"></p>
          </form>
          <aside class="policy"><h3>Effective policy</h3><dl id="settings"></dl></aside>
        </div>
      </section>
    </main>
  </div>
  <script>
    const $=id=>document.getElementById(id);
    const state={npcs:[],selected:null,definition:null,residents:[]};
    const auth=()=>({'X-AI-NPC-Secret':$('secret').value});
    async function api(path,options={}){const response=await fetch(path,{...options,headers:{...(options.body?{'content-type':'application/json'}:{}),...auth(),...(options.headers||{})}});let data={};try{data=await response.json()}catch{}if(!response.ok)throw new Error(data.error||('HTTP '+response.status));return data}
    const empty=(columns,text)=>'<tr><td class="empty" colspan="'+columns+'">'+text+'</td></tr>';
    const raw=value=>String(value??'');
    const clean=value=>raw(value).replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
    const short=value=>{const text=raw(value);return clean(text.length>28?text.slice(0,25)+'…':text)};
    function rows(target,values,render,columns,label){$(target).innerHTML=values.length?values.map(render).join(''):empty(columns,label)}
    function selectView(id){document.querySelectorAll('.view').forEach(view=>view.hidden=view.id!==id);document.querySelectorAll('nav button').forEach(button=>button.classList.toggle('active',button.dataset.view===id));$('viewTitle').textContent={overview:'Overview',npcs:'NPC studio',residents:'Residents',conversations:'Conversations',privacy:'Privacy'}[id]}
    document.querySelectorAll('nav button').forEach(button=>button.onclick=()=>selectView(button.dataset.view));
    async function loadOverview(){
      const health=await fetch('/health').then(r=>r.json());$('healthDot').classList.toggle('ok',health.ok===true);$('mText').textContent=raw(health.provider);$('mSpeech').textContent=raw(health.speech);$('mStt').textContent=raw(health.transcription);$('mMemory').textContent=raw(health.memory);
      const [serverData,usageData]=await Promise.all([api('/v1/servers'),api('/v1/usage')]);
      rows('serverRows',serverData.servers||[],s=>'<tr><td>'+short(s.name||s.serverId)+'</td><td>'+clean(s.version||'—')+'</td><td>'+new Date(s.lastSeenAt).toLocaleString()+'</td></tr>',3,'No server heartbeat yet.');
      rows('usageRows',usageData.servers||[],u=>'<tr><td>'+short(u.serverId)+'</td><td>'+clean(u.totalRequests)+'</td><td>'+clean(u.totalInputTokens)+' / '+clean(u.totalOutputTokens)+'</td><td>'+clean(u.failures)+'</td><td>'+clean(u.averageLatencyMs)+' ms</td></tr>',5,'No metered turns yet.');
    }
    function blankDefinition(){return{model:'mp_m_shopkeep_01',coords:{x:0,y:0,z:30,w:0},identity:{name:'New NPC',occupation:'contact'},enabled:true,personality:'Concise and grounded.',knowledge:'Use only configured context and tool results.',voice:{voice:'',language:'en'},allowedTools:[],interactionDistance:3}}
    function fillNpc(id,definition){state.selected=id;state.definition=structuredClone(definition);$('npcId').value=id||'';$('npcId').disabled=!!id;$('model').value=raw(definition.model);$('npcName').value=raw(definition.identity?.name);$('occupation').value=raw(definition.identity?.occupation);$('coordX').value=raw(definition.coords?.x);$('coordY').value=raw(definition.coords?.y);$('coordZ').value=raw(definition.coords?.z);$('coordW').value=raw(definition.coords?.w);$('personality').value=raw(definition.personality);$('knowledge').value=raw(definition.knowledge);$('voiceId').value=raw(definition.voice?.voice);$('voiceLanguage').value=raw(definition.voice?.language);$('tools').value=(definition.allowedTools||[]).join(', ');$('distance').value=raw(definition.interactionDistance??3);$('enabled').checked=definition.enabled!==false;renderNpcList()}
    function renderNpcList(){const buttons=state.npcs.map(entry=>'<button type="button" data-id="'+entry.id+'" class="'+(entry.id===state.selected?'active':'')+'">'+clean(entry.definition?.identity?.name||entry.id)+'<br><small>'+clean(entry.id)+'</small></button>').join('');$('npcList').innerHTML=buttons||'<p class="notice">No catalog NPCs.</p>';$('npcList').querySelectorAll('button').forEach(button=>button.onclick=()=>{const entry=state.npcs.find(item=>item.id===button.dataset.id);if(entry)fillNpc(entry.id,entry.definition)})}
    async function loadNpcs(){const data=await api('/v1/npcs?serverId='+encodeURIComponent($('serverId').value));state.npcs=data.npcs||[];const selected=state.npcs.find(entry=>entry.id===state.selected)||state.npcs[0];if(selected)fillNpc(selected.id,selected.definition);else fillNpc('',blankDefinition())}
    function formDefinition(){const base=state.definition?structuredClone(state.definition):{};return{...base,model:$('model').value.trim(),coords:{x:Number($('coordX').value),y:Number($('coordY').value),z:Number($('coordZ').value),w:Number($('coordW').value)},identity:{name:$('npcName').value.trim(),occupation:$('occupation').value.trim()},enabled:$('enabled').checked,personality:$('personality').value.trim(),knowledge:$('knowledge').value.trim(),voice:{...(base.voice||{}),voice:$('voiceId').value.trim(),language:$('voiceLanguage').value.trim()},allowedTools:$('tools').value.split(',').map(x=>x.trim()).filter(Boolean),interactionDistance:Number($('distance').value)}}
    $('npcForm').onsubmit=async event=>{event.preventDefault();const id=$('npcId').value.trim();try{await api('/v1/npcs/'+encodeURIComponent($('serverId').value)+'/'+encodeURIComponent(id),{method:'PUT',body:JSON.stringify(formDefinition())});$('npcNotice').className='notice';$('npcNotice').textContent='Saved. The resource reconciles this definition on its next catalog load.';state.selected=id;await loadNpcs()}catch(error){$('npcNotice').className='notice error';$('npcNotice').textContent=error.message}};
    $('newNpc').onclick=()=>fillNpc('',blankDefinition());$('reloadNpc').onclick=()=>{if(state.selected){const entry=state.npcs.find(item=>item.id===state.selected);if(entry)fillNpc(entry.id,entry.definition)}else fillNpc('',blankDefinition())};
    $('deleteNpc').onclick=async()=>{if(!state.selected||!confirm('Delete '+state.selected+' from this server catalog?'))return;try{await api('/v1/npcs/'+encodeURIComponent($('serverId').value)+'/'+encodeURIComponent(state.selected),{method:'DELETE'});state.selected=null;await loadNpcs();$('npcNotice').textContent='NPC deleted.'}catch(error){$('npcNotice').className='notice error';$('npcNotice').textContent=error.message}};
    async function loadConversations(){const data=await api('/v1/conversations?serverId='+encodeURIComponent($('serverId').value));rows('conversationRows',data.conversations||[],c=>'<tr><td>'+new Date(c.createdAt).toLocaleTimeString()+'</td><td>'+clean(c.npcId)+'</td><td title="'+clean(c.sessionId)+'">'+short(c.sessionId)+'</td><td>'+clean(c.provider)+'</td><td>'+clean(c.latencyMs)+' ms</td><td>'+clean(c.result)+'</td></tr>',6,'No recorded turns for this server process.')}
    async function residentAction(id,event){if(event==='retire'){if(!confirm('Permanently retire this resident and associated identity data?'))return;await api('/v1/residents/'+encodeURIComponent($('serverId').value)+'/'+encodeURIComponent(id),{method:'DELETE'});}else await api('/v1/residents/lifecycle',{method:'POST',body:JSON.stringify({serverId:$('serverId').value,residentId:id,event})});await loadResidents()}
    function inspectResident(id){const resident=state.residents.find(value=>value.residentId===id);if(resident)alert(JSON.stringify(resident,null,2))}
    function renderResidents(){const query=$('residentSearch').value.trim().toLowerCase();const values=state.residents.filter(r=>!query||[r.name,r.residentId,r.occupation,r.status,r.activity].some(value=>raw(value).toLowerCase().includes(query)));rows('residentRows',values,r=>'<tr><td title="'+clean(r.residentId)+'">'+clean(r.name)+(r.pinned?' ★':'')+'</td><td>'+clean(r.occupation)+'</td><td>'+clean(r.status)+'</td><td>'+clean(r.activity)+'</td><td>'+clean(r.mood)+'</td><td>'+new Date(r.lastSeenAt).toLocaleString()+'</td><td><button class="button" onclick="inspectResident(\\''+clean(r.residentId)+'\\')">Inspect</button> <button class="button" onclick="residentAction(\\''+clean(r.residentId)+'\\',\\''+(r.pinned?'unpin':'pin')+'\\')">'+(r.pinned?'Unpin':'Pin')+'</button> <button class="button" onclick="residentAction(\\''+clean(r.residentId)+'\\',\\'respawn\\')">Respawn</button> <button class="button" onclick="residentAction(\\''+clean(r.residentId)+'\\',\\'archive\\')">Archive</button> <button class="button danger" onclick="residentAction(\\''+clean(r.residentId)+'\\',\\'retire\\')">Retire</button></td></tr>',7,'No matching residents.')}
    async function loadResidents(){const data=await api('/v1/residents?archived=true&serverId='+encodeURIComponent($('serverId').value));const s=data.stats||{},q=s.extractionQueue||{};state.residents=data.residents||[];$('residentStats').textContent='Profiles '+(s.total||0)+' · active '+(s.active||0)+' · recovering '+(s.recovering||0)+' · archived '+(s.archived||0)+' · known names '+(s.knownNames||0)+' · memory queue '+(q.depth||0)+' / running '+(q.running||0)+' / failed '+(q.failed||0)+' / dropped '+(q.dropped||0);renderResidents()}
    $('residentSearch').oninput=renderResidents;
    $('simulateResidents').onclick=async()=>{await api('/v1/residents/simulate',{method:'POST',body:JSON.stringify({serverId:$('serverId').value})});await loadResidents()};
    async function loadSettings(){const data=await api('/v1/settings');$('settings').innerHTML=Object.entries(data).map(([key,value])=>'<div><dt>'+clean(key)+'</dt><dd>'+clean(value)+'</dd></div>').join('')}
    $('forgetForm').onsubmit=async event=>{event.preventDefault();try{const id=$('forgetNpc').value;const resident=id.startsWith('resident:');const data=await api(resident?'/v1/residents/forget':'/v1/memory/delete',{method:'POST',body:JSON.stringify(resident?{serverId:$('serverId').value,residentId:id,characterId:$('characterId').value}:{serverId:$('serverId').value,npcId:id,characterId:$('characterId').value})});$('privacyNotice').className='notice';$('privacyNotice').textContent='Deleted '+data.deleted+' scoped identity, memory, and relationship records.'}catch(error){$('privacyNotice').className='notice error';$('privacyNotice').textContent=error.message}};
    async function refresh(){try{await Promise.all([loadOverview(),loadNpcs(),loadResidents(),loadConversations(),loadSettings()]);$('globalNotice').textContent=''}catch(error){$('globalNotice').textContent=error.message==='unauthorized'?'Enter the gateway secret to unlock controls.':error.message}}
    $('refresh').onclick=refresh;$('serverId').onchange=refresh;refresh();
  </script>
</body>
</html>`;
