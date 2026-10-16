// Read-only app-server RPC. No threads, turns, prompts, or inference requests.
const {spawn}=require('node:child_process');
const fs=require('node:fs');
const path=require('node:path');
const readline=require('node:readline');
const candidates=[process.env.CODEX_WIDGET_CODEX_EXE,
 path.join(process.env.APPDATA||'', 'npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe')].filter(Boolean);
const exe=candidates.find(p=>fs.existsSync(p));
if(!exe){console.error('Codex CLI not found. Install it or set CODEX_WIDGET_CODEX_EXE.');process.exit(1);}
const child=spawn(exe,['app-server'],{windowsHide:true,stdio:['pipe','pipe','pipe']});
let finished=false;
const timer=setTimeout(()=>finish('Usage query timed out. Check Codex CLI sign-in.'),20000);
function send(msg){child.stdin.write(JSON.stringify(msg)+'\n');}
function finish(error,result){
 if(finished)return;finished=true;clearTimeout(timer);
 if(error){console.error(error);process.exitCode=1;}else console.log(JSON.stringify(result));
 child.kill();
}
function bucket(b){return b?{utilization:b.usedPercent,resets_at:b.resetsAt?new Date(b.resetsAt*1000).toISOString():null}:null;}
child.on('error',()=>finish('Unable to start Codex app-server.'));
child.on('exit',()=>{if(!finished)finish('Codex app-server stopped before returning usage.');});
// Drain diagnostics without logging credentials or account details.
child.stderr.on('data',()=>{});
readline.createInterface({input:child.stdout}).on('line',line=>{
 let m;try{m=JSON.parse(line);}catch{return;}
 if(m.id===1){
  if(m.error)return finish(m.error.message||'Codex initialization failed.');
  send({method:'initialized',params:{}});
  send({id:2,method:'account/rateLimits/read'});
 }
 if(m.id===2){
  if(m.error)return finish(m.error.message||'Usage unavailable. Run codex login.');
  const r=m.result||{};
  const b=r.rateLimitsByLimitId?.codex||r.rateLimits;
  if(!b)return finish('No subscription usage returned. Sign the Codex CLI into ChatGPT.');
  finish(null,{five_hour:bucket(b.primary),seven_day:bucket(b.secondary)});
 }
});
send({id:1,method:'initialize',params:{clientInfo:{name:'codex_usage_widget',title:'Codex Usage Widget',version:'1.0.0'}}});
