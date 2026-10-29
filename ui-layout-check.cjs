// CI-only WebKit layout verification. Does not contact a controller, phone, or external website.
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const {webkit}=require('playwright');
const root=__dirname, out=path.join(root,'ui-preview');
fs.mkdirSync(out,{recursive:true});
const source=fs.readFileSync(path.join(root,'index.html'));
const reports=[],failures=[];
const server=http.createServer((req,res)=>{
  if(req.url!=='/'&&req.url!=='/index.html'){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'});res.end(source);
});
const viewports=[{width:852,height:393,safe:59},{width:667,height:375,safe:0},{width:932,height:430,safe:59}];

async function measure(page,screen,size){
  const rootSelector=screen==='drive'?'#driveScreen':screen==='skins'?'#skinPicker':'#settingsPanel';
  const geometry=await page.evaluate(({rootSelector,screen})=>{
    const root=document.querySelector(rootSelector), violations=[],notes=[];
    const rect=e=>{const b=e.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height,right:b.right,bottom:b.bottom};};
    const visible=e=>{const s=getComputedStyle(e),r=rect(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'&&Number(s.opacity)!==0;};
    const controls=[...root.querySelectorAll('button,[role="button"]')].filter(visible);
    const items=controls.map((el,index)=>({id:el.id||`${el.tagName}-${index}`,label:(el.getAttribute('aria-label')||el.textContent).trim().replace(/\s+/g,' '),...rect(el)}));
    for(let index=0;index<controls.length;index++){
      const el=controls[index],item=items[index];
      if(item.id==='driveStatus')notes.push(`${item.id}: secondary status link, touch minimum exempt (${item.width.toFixed(1)}×${item.height.toFixed(1)})`);
      else if(item.width<43.5||item.height<43.5)violations.push(`${item.id}: touch target ${item.width.toFixed(1)}×${item.height.toFixed(1)} is below 44×44`);
      if(item.id!=='driveStatus'&&el.scrollWidth>el.clientWidth+1)violations.push(`${item.id}: button content overflows by ${el.scrollWidth-el.clientWidth}px`);
      if(item.x<-.5||item.y<-.5||item.right>innerWidth+.5||item.bottom>innerHeight+.5)violations.push(`${item.id}: outside viewport`);
      // Hit-testing inner points detects an overlay covering a visible control, including transparent overlays.
      for(const [fx,fy] of [[.5,.5],[.2,.2],[.8,.2],[.2,.8],[.8,.8]]){
        const at=document.elementFromPoint(item.x+item.width*fx,item.y+item.height*fy);
        if(at!==el&&!el.contains(at))violations.push(`${item.id}: obscured at ${fx},${fy} by ${at?.id||at?.tagName||'outside viewport'}`);
      }
      for(let other=index+1;other<controls.length;other++){
        if(el.contains(controls[other])||controls[other].contains(el))continue;
        const b=items[other],w=Math.min(item.right,b.right)-Math.max(item.x,b.x),h=Math.min(item.bottom,b.bottom)-Math.max(item.y,b.y);
        if(w>1&&h>1)violations.push(`${item.id} overlaps ${b.id} (${w.toFixed(1)}×${h.toFixed(1)})`);
      }
    }
    const inspected=screen==='settings'?[root,...root.querySelectorAll('#menuCards,.menu-section,#nativeSettingsGroup,#anglePresets,#steeringAssistModes,#steeringAssistStrengths,.menu-footer')]:[root];
    for(const el of inspected){
      if(el.clientWidth>0&&el.scrollWidth>el.clientWidth+1)violations.push(`${el.id||el.className}: horizontal overflow ${el.scrollWidth-el.clientWidth}px`);
      if(el.clientHeight>0&&el.scrollHeight>el.clientHeight+1)violations.push(`${el.id||el.className}: vertical overflow ${el.scrollHeight-el.clientHeight}px`);
    }
    if(screen==='settings'){
      const panel=rect(root);if(panel.x<-.5||panel.y<-.5||panel.right>innerWidth+.5||panel.bottom>innerHeight+.5)violations.push('settings panel exceeds viewport');
    }
    return {controls:items,violations:[...new Set(violations)],notes};
  },{rootSelector,screen});
  const report={viewport:size,screen,...geometry};reports.push(report);
  for(const error of geometry.violations)failures.push(`${size.width}×${size.height} ${screen}: ${error}`);
}

async function main(){
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const browser=await webkit.launch({headless:true});
  try{
    for(const size of viewports){
      const context=await browser.newContext({viewport:{width:size.width,height:size.height},deviceScaleFactor:2,isMobile:true,hasTouch:true,locale:'zh-CN',colorScheme:'dark',reducedMotion:'reduce'});
      const page=await context.newPage(),pageErrors=[],blocked=[];
      page.on('pageerror',error=>pageErrors.push(String(error)));
      await context.route('**/*',route=>{
        const requested=new URL(route.request().url());
        if(requested.origin===origin)return route.continue();
        blocked.push(requested.origin);return route.abort('blockedbyclient');
      });
      await page.addInitScript(()=>{
        localStorage.setItem('maxAngleDeg','45');
        localStorage.setItem('steeringAssistMode','adaptive');
        localStorage.setItem('steeringAssistStrength','standard');
        // Only replace unavailable native/network boundaries; production layout and interaction code stay intact.
        window.__nativeRequestMotion=async()=> 'granted';window.__nativeStopMotion=()=>{};
        window.__nativeRaceFeedback=()=>{};window.__nativeSteeringLimit=()=>{};window.__nativeCurbImpact=()=>{};
        class PreviewSocket {
          static CONNECTING=0;static OPEN=1;static CLOSING=2;static CLOSED=3;
          constructor(){this.readyState=0;queueMicrotask(()=>{this.readyState=1;this.onopen?.(new Event('open'));});}
          send(){} close(){this.readyState=3;this.onclose?.(new Event('close'));}
        }
        window.WebSocket=PreviewSocket;
      });
      try{
        await page.goto(origin,{waitUntil:'load'});
        await page.evaluate(async(safe)=>{
          await document.fonts.ready;
          document.documentElement.style.setProperty('--wheel-safe-left',safe+'px');
          document.documentElement.style.setProperty('--wheel-safe-right',safe+'px');
          document.documentElement.style.setProperty('--wheel-safe-bottom',(safe?21:0)+'px');
          // Match the two buttons injected by WheelViewController.didFinish in the native app.
          ['certBtn','certBtn2','fullscreenBtn1','fullscreenBtn2'].forEach(id=>{const e=document.getElementById(id);if(e)e.style.display='none';});
          [['nativeNetworkSettings','网络连接'],['nativeHapticSettings','震动设置']].forEach(([id,title])=>{
            if(document.getElementById(id))return;const b=document.createElement('button');b.id=id;b.textContent=title;b.onclick=()=>{};
            document.getElementById('nativeSettingsGroup').append(b);
          });
          await start();
          const telemetry={valid:true,spd:247,gear:6,rpm:11300,rpmPct:84,rpmBits:4095,drs:false,statusValid:true,drsAllowed:true,drsDistance:0,surfaceTypes:[0,0,0,0]};
          onTelemetry(telemetry);
          window.__previewTelemetryTimer=setInterval(()=>{onTelemetry(telemetry);lastMotionAt=Date.now();filteredRoll=7;},50);
          autoCalibratePending=false;lastMotionAt=Date.now();filteredRoll=7;
          controls.fullThrottle=true;sendImmediatePedals();updateSteeringValue();updateSteeringMeter(normalized);
        },size.safe);
        await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
        await page.screenshot({path:path.join(out,`drive-${size.width}x${size.height}.png`),fullPage:false,animations:'disabled'});
        await measure(page,'drive',size);
        const displayGeometry=await page.locator('#telemetryStrip').boundingBox();
        if(displayGeometry.width<185||displayGeometry.height<140)failures.push(`${size.width}×${size.height}: central display too small`);
        await page.evaluate(()=>selectControllerSkin('classic'));
        await measure(page,'drive',size);
        await page.screenshot({path:path.join(out,`classic-${size.width}x${size.height}.png`),animations:'disabled'});
        await page.evaluate(()=>selectControllerSkin('f1'));
        await measure(page,'drive',size);
        await page.screenshot({path:path.join(out,`f1-${size.width}x${size.height}.png`),animations:'disabled'});
        await page.evaluate(()=>selectControllerSkin('race'));
        await measure(page,'drive',size);
        await page.screenshot({path:path.join(out,`race-${size.width}x${size.height}.png`),animations:'disabled'});
        // Exercise the actual settings button, preserving its control-release behavior.
        await page.locator('#settingsBtn').click();
        await page.locator('#assistAdaptiveBtn').click();
        await page.screenshot({path:path.join(out,`settings-${size.width}x${size.height}.png`),fullPage:false,animations:'disabled'});
        await measure(page,'settings',size);
        await page.locator('#skinSettingsBtn').click();
        for(const id of ['race','f1','classic']){
          await page.locator(`[data-skin-choice="${id}"]`).click();
          const saved=await page.evaluate(()=>localStorage.getItem('controllerSkin'));
          if(saved!==id)failures.push(`${size.width}×${size.height}: skin not persisted ${id}`);
        }
        await page.screenshot({path:path.join(out,`skins-${size.width}x${size.height}.png`),animations:'disabled'});
        await measure(page,'skins',size);
        await page.locator('#closeSkinBtn').click();
        if(await page.locator('#skinPicker').isVisible())failures.push('Skin picker did not close');
        await page.locator('[data-angle="30"]').click();
        if(await page.evaluate(()=>maxAngleDeg)!==30)failures.push('30 degree setting did not apply');
      }catch(error){
        failures.push(`${size.width}×${size.height}: ${error.stack||error}`);
        await page.screenshot({path:path.join(out,`failure-${size.width}x${size.height}.png`),fullPage:false}).catch(()=>{});
      }finally{
        for(const error of pageErrors)failures.push(`${size.width}×${size.height} page error: ${error}`);
        if(blocked.length)failures.push(`${size.width}×${size.height}: attempted external requests: ${[...new Set(blocked)].join(',')}`);
        await context.close();
      }
    }
  }finally{await browser.close();}
  fs.writeFileSync(path.join(out,'layout-results.json'),JSON.stringify({reports,failures},null,2));
  if(failures.length){console.error(failures.join('\n'));throw new Error(`UI layout check failed with ${failures.length} findings`);}
  console.log(`PASS: ${viewports.length} touch viewports, drive and settings, 44px action targets, overlap/occlusion/overflow checks; screenshots in ui-preview/`);
}
main().catch(error=>{
  console.error(error.stack||error);process.exitCode=1;
  fs.writeFileSync(path.join(out,'layout-results.json'),JSON.stringify({reports,failures,fatal:String(error)},null,2));
}).finally(()=>server.close());
