import {test} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {JSDOM} from 'jsdom';
const dom=new JSDOM('');globalThis.window=dom.window;globalThis.document=dom.window.document;
async function moduleAt(path){const {outputFiles}=await build({entryPoints:[path],bundle:true,write:false,format:'esm',platform:'node',packages:'external'});return import('data:text/javascript;base64,'+Buffer.from(outputFiles[0].text).toString('base64'))}
const table=await moduleAt('src/features/notes/editor-enhancements/table.ts');
const format=await moduleAt('src/features/notes/editor-enhancements/inline-format.ts');
const callout=await moduleAt('src/features/notes/editor-enhancements/callout.ts');
const list=await moduleAt('src/features/notes/editor-enhancements/list.ts');
test('indenting an ordered item starts a fresh nested list at one',()=>{
    const edit=list.indentMarkdownListItem('1. parent\n2. child',19);
    assert.equal(edit.insert,'\t1. child');
    assert.equal(list.indentMarkdownListItem('- child',7).insert,'\t- child');
});
test('table preserves escaped pipes and excludes fences',()=>{const source='| A\\|B | `x|y` |\n| --- | --- |\n| 中 | 文 |';const edit=table.addMarkdownTableColumn(source,3);assert.ok(edit.insert.includes('A\\|B'));assert.ok(edit.insert.includes('`x|y`'));assert.equal(table.addMarkdownTableColumn('```\n'+source+'\n```',10),null)});
test('format removes enclosing marks and preserves caret',()=>{const edit=format.toggleInlineFormat('**中文内容**',4,4,'**');assert.equal(edit.insert,'中文内容');assert.equal(edit.anchor,2)});
test('callout insertion preserves existing quote',()=>{const edit=callout.buildCalloutInsertion('> [!note]\n> 正文\n后文',12,12,'warning','');assert.ok(edit.insert.startsWith('\n\n> [!warning]'));assert.equal(edit.from,14)});

test('list continuation matches reference and increments ordered list',()=>{const edit=list.continueMarkdownListItem('1. completed',12);assert.equal(edit.insert,'\n2. ')});
test('second Enter on an empty nested item returns to the parent sequence',()=>{
    const source='1. parent\n\t1. child\n\t2. ';
    const edit=list.exitEmptyRootListItem(source, source.length);
    assert.equal(edit.insert,'2. ');
    assert.equal(source.slice(0, edit.from)+edit.insert+source.slice(edit.to),'1. parent\n\t1. child\n2. ');
});
const rendered=await build({entryPoints:['src/markdown.ts'],bundle:true,write:false,format:'esm',platform:'browser'});
const renderer=await import('data:text/javascript;base64,'+Buffer.from(rendered.outputFiles[0].text).toString('base64'));
test('outline excludes fenced headings and keeps source offsets',()=>{const source='# 中文\n\n```\n# hidden\n```\n\n## 第二节';const headings=renderer.extractMarkdownHeadings(source);assert.deepEqual(headings.map(h=>h.text),['中文','第二节']);assert.equal(source.slice(headings[1].offset,headings[1].offset+3),'## ')});
test('canonical wiki anchor is retained and raw HTML stays literal',()=>{const id='9414d9ee-e998-4ef1-97b8-74d3901c3b44';const html=renderer.renderMarkdown(`[[学习#核心|${id}#核心]]\n\n<script>alert(1)</script>`);assert.ok(html.includes('station-note:'+id));assert.ok(html.includes('data-note-heading="核心"'));assert.ok(!html.includes('<script>'));assert.ok(html.includes('&lt;script&gt;'))});
const links=await moduleAt('src/features/notes/noteLinks.ts');
test('wiki relation extraction preserves canonical anchors and deduplicates targets',()=>{const id='9414d9ee-e998-4ef1-97b8-74d3901c3b44';const result=links.extractNoteLinks(`[[学习|${id}#核心]] [[重复|${id}]]`);assert.deepEqual(result,[{id,label:'学习',heading:'核心'}])});
const clipboard = await moduleAt('src/shared/clipboard.ts');
const scenes = await moduleAt('src/features/notes/excalidrawScene.ts');
test('canvas parsing preserves drawing elements and embedded images', () => {
    const scene = {elements: [{id: 'shape', type: 'rectangle'}], files: {image: {dataURL: 'data:image/png;base64,test'}}, appState: {viewBackgroundColor: '#fff', zoom: {value: 2}}};
    const parsed = scenes.parseExcalidrawScene(JSON.stringify(scene));
    assert.deepEqual(parsed.elements, scene.elements);
    assert.deepEqual(parsed.files, scene.files);
    assert.equal(parsed.appState.zoom.value, 2);
    assert.equal(parsed.appState.viewBackgroundColor, 'transparent');
    for (const invalid of ['null', '[]', '{broken', '{}', '{"elements":{}}', '{"elements":[null]}']) assert.equal(scenes.parseExcalidrawScene(invalid), null);
});
test('native clipboard preserves Unicode and propagates write failures', async () => {
    let text = '';
    window.webkit = {messageHandlers: {noteClipboard: {postMessage: async message => {
        if (message.action === 'read') return text;
        text = message.text;
        return true;
    }}}};
    try {
        await clipboard.writeClipboardText('中文 **笔记** 🌏\n第二行');
        assert.equal(await clipboard.readClipboardText(), '中文 **笔记** 🌏\n第二行');
        window.webkit.messageHandlers.noteClipboard.postMessage = async () => false;
        await assert.rejects(clipboard.writeClipboardText('失败'), /无法写入/);
        await assert.rejects(clipboard.readClipboardText(), /内容无效/);
        window.webkit.messageHandlers.noteClipboard.postMessage = async () => {throw new Error('原生桥接失败')};
        await assert.rejects(clipboard.writeClipboardText('失败'), /原生桥接失败/);
    } finally {
        delete window.webkit;
    }
});
