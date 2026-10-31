import {build} from 'esbuild';
import {mkdir,copyFile,readFile,writeFile,readdir,cp} from 'node:fs/promises';
const out='../../Resources/NoteWeb';
await mkdir(out,{recursive:true});
await build({entryPoints:['src/react-app.tsx'],bundle:true,minify:true,format:'iife',target:'safari17',outfile:out+'/editor.js',legalComments:'eof',define:{'process.env.NODE_ENV':'"production"'},conditions:['production']});
await copyFile('src/index.html',out+'/index.html');
const {default:postcss}=await import('postcss');
const {default:tailwind}=await import('@tailwindcss/postcss');
const css=await postcss([tailwind({base:process.cwd()})]).process((await readFile('src/station.css','utf8'))+'\n'+(await readFile('src/features/notes/components/markdown-preview.css','utf8')).replace(/@reference[^;]+;/,''),{from:'src/station.css'});
await writeFile(out+'/editor.css',css.css+'\n'+await readFile('node_modules/@excalidraw/excalidraw/dist/prod/index.css','utf8')+'\n'+await readFile('src/features/notes/components/excalidraw.css','utf8')+'\n'+await readFile('src/shell.css','utf8'));


const seen=new Set();let notices='Third-party dependency licenses\n';
async function walk(path){for(const entry of await readdir(path,{withFileTypes:true})){const file=path+'/'+entry.name;if(entry.isDirectory())await walk(file);else if(entry.isFile()&&/^(licen[sc]e|copying|notice)(\.|$)/i.test(entry.name)){const text=await readFile(file,'utf8');if(!seen.has(text)){seen.add(text);notices+='\n\n--- '+file+' ---\n'+text}}}}
await walk('node_modules/.pnpm');await writeFile(out+'/THIRD-PARTY-NOTICES.txt',notices);



await cp('node_modules/@excalidraw/excalidraw/dist/prod/fonts',out+'/fonts',{recursive:true});
