import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { createRequire } from 'node:module';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('scene switches install the fitted viewport atomically and never save navigation', async () => {
  const dom = new JSDOM('<div id="root"></div>');
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  let width = 1000;
  let height = 800;
  Object.defineProperties(dom.window.HTMLElement.prototype, {
    clientWidth: {get: () => width},
    clientHeight: {get: () => height},
  });
  const observers = new Set();
  globalThis.ResizeObserver = class {
    constructor(callback) { this.callback = callback; }
    observe() { observers.add(this); }
    disconnect() { observers.delete(this); }
  };
  const NativeChannel = globalThis.MessageChannel;
  const channels = [];
  globalThis.MessageChannel = class extends NativeChannel { constructor() { super(); channels.push(this); } };
  const frames = new Map();
  let frameID = 0;
  globalThis.requestAnimationFrame = callback => { frames.set(++frameID, callback); return frameID; };
  globalThis.cancelAnimationFrame = id => frames.delete(id);
  const directory = await mkdtemp(join(tmpdir(), 'notes-canvas-test-'));
  const mock = `import {useLayoutEffect} from 'react';
    export function Excalidraw(props) {
      globalThis.canvasProps = props;
      useLayoutEffect(() => { props.excalidrawAPI(globalThis.canvasAPI); props.onChange([], {isLoading:false}, {}); }, []);
      return null;
    }
    export function getCommonBounds(elements) {
      if (!elements.length) return [0,0,0,0];
      return [Math.min(...elements.map(e=>e.x)),Math.min(...elements.map(e=>e.y)),Math.max(...elements.map(e=>e.x+e.width)),Math.max(...elements.map(e=>e.y+e.height))];
    }
    export const serializeAsJSON = (elements, appState) => JSON.stringify({elements,appState});`;
  const output = await build({stdin:{contents:`export {ExcalidrawCanvas} from './src/features/notes/components/ExcalidrawCanvas'; export {createElement,act} from 'react'; export {createRoot} from 'react-dom/client';`,resolveDir:process.cwd()},bundle:true,write:false,format:'cjs',platform:'browser',plugins:[{name:'excalidraw-test-adapter',setup(builder){builder.onResolve({filter:/^@excalidraw\/excalidraw$/},()=>({path:'excalidraw',namespace:'mock'}));builder.onLoad({filter:/.*/,namespace:'mock'},()=>({contents:mock,resolveDir:process.cwd(),loader:'jsx'}));}}]});
  const file = join(directory,'test.cjs');
  await writeFile(file,output.outputFiles[0].contents);
  const {ExcalidrawCanvas,createElement,act,createRoot} = createRequire(import.meta.url)(file);
  let elements = [];
  const updates = [];
  // The library's cached size can still be zero when its hidden host returns.
  globalThis.canvasAPI = {resetScene(){elements=[];},updateScene(update){elements=update.elements;updates.push(update);},history:{clear(){}},addFiles(){},getSceneElements(){return elements;},getAppState(){return {width:0,height:0};}};
  const changes = [];
  const root = createRoot(document.getElementById('root'));
  const scene = (id,x,width) => JSON.stringify({elements:[{id,type:'rectangle',x,y:0,width,height:100,version:1,versionNonce:1,isDeleted:false}],files:{},appState:{}});
  const render = async (id,value,active=true,readonly=false) => act(async()=>{root.render(createElement(ExcalidrawCanvas,{documentKey:id,value,active,readonly,onChange:value=>changes.push(value)}));});
  const flush = async () => act(async()=>{const pending=[...frames.values()];frames.clear();pending.forEach(callback=>callback());});
  try {
    await render('a',scene('a',0,200));
    await flush();
    await flush();
    await render('b',scene('b',2000,2000));
    assert.equal(document.querySelector('.excalidraw-canvas').dataset.ready,'false','a reused canvas stays hidden while its viewport is committed');
    const update=updates.at(-1);
    assert.equal(update.elements[0].id,'b');
    assert.ok(update.appState.zoom.value<1);
    const left=(2000+update.appState.scrollX)*update.appState.zoom.value;
    const right=(4000+update.appState.scrollX)*update.appState.zoom.value;
    assert.ok(left>=0 && right<=1000,'new content fits before any animation frame');
    await flush();
    assert.equal(document.querySelector('.excalidraw-canvas').dataset.ready,'false','do not reveal before the canvas paint frame');
    await flush();
    assert.equal(document.querySelector('.excalidraw-canvas').dataset.ready,'true');
    await render('huge',scene('huge',0,100_000));
    const huge=updates.at(-1);
    assert.ok(huge.appState.zoom.value<0.1,'a wide drawing must fit below the normal toolbar zoom limit');
    assert.ok((100_000+huge.appState.scrollX)*huge.appState.zoom.value<=1000);
    await flush();
    await flush();
    const hidden=scene('hidden',0,2000);
    await render('huge',scene('huge',0,100_000),false);
    width=0; height=0;
    const count=updates.length;
    await render('hidden',hidden);
    assert.equal(updates.length,count,'do not install a scene into a zero-sized viewport');
    await flush();
    assert.equal(document.querySelector('.excalidraw-canvas').dataset.ready,'false');
    width=1000; height=800;
    await act(async()=>observers.forEach(observer=>observer.callback()));
    assert.equal(updates.at(-1).elements[0].id,'hidden');
    assert.ok(updates.at(-1).appState.zoom.value>0.4,'use the visible DOM size, not the stale API size');
    await flush();
    await flush();
    assert.equal(document.querySelector('.excalidraw-canvas').dataset.ready,'true');
    await act(async()=>globalThis.canvasProps.onChange(elements,{scrollX:900},{}));
    assert.deepEqual(changes,[],'opening, fitting and panning must not save');
    await act(async()=>globalThis.canvasProps.onChange([{...elements[0],version:2}],{},{}));
    assert.equal(changes.length,1,'a real edit still reaches autosave');
    await render('rapid-a',scene('rapid-a',0,200));
    await flush();
    await render('rapid-b',scene('rapid-b',0,2000));
    await flush();
    assert.equal(document.querySelector('.excalidraw-canvas').dataset.ready,'false','an old scene must not reveal a newer pending scene');
    await flush();
    assert.equal(updates.at(-1).elements[0].id,'rapid-b');
    assert.equal(document.querySelector('.excalidraw-canvas').dataset.ready,'true');
    assert.equal(changes.length,1,'rapid navigation must not reach autosave');
  } finally {
    await act(async()=>root.unmount());
    dom.window.close();
    channels.forEach(channel => { channel.port1.close(); channel.port2.close(); });
    globalThis.MessageChannel = NativeChannel;
    await rm(directory,{recursive:true,force:true});
  }
});
