import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
const here=path.dirname(fileURLToPath(import.meta.url));
const outfile=path.resolve(here,'Resources/vendor/live-editor.bundle.js');
const result=await build({entryPoints:[path.resolve(here,'Resources/live-editor.js')],outfile,bundle:true,minify:true,format:'iife',platform:'browser',target:['safari16'],nodePaths:[path.join(here,'node_modules')],legalComments:'eof',metafile:true});
const packages=new Map();
for(const input of Object.keys(result.metafile.inputs)){
 if(!input.includes('node_modules/'))continue;
 let dir=path.dirname(path.resolve(input));
 while(dir!==path.dirname(dir)&&!fs.existsSync(path.join(dir,'package.json')))dir=path.dirname(dir);
 if(packages.has(dir)||!fs.existsSync(path.join(dir,'package.json')))continue;
 const pkg=JSON.parse(fs.readFileSync(path.join(dir,'package.json'),'utf8'));
 const license=['LICENSE','LICENSE.md','LICENSE.txt'].find(name=>fs.existsSync(path.join(dir,name)));
 packages.set(dir,`${pkg.name} ${pkg.version}\n${license?fs.readFileSync(path.join(dir,license),'utf8'):pkg.license}`);
}
fs.appendFileSync(outfile,'\n/*\nBundled offline dependencies and licenses:\n\n'+[...packages.values()].join('\n\n----------------\n\n').replaceAll('*/','* /')+'\n*/\n');
console.log('Built offline live editor ('+packages.size+' licensed runtime packages).');
