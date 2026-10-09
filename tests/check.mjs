import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';

const root=new URL('../',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('Renoise manifest targets API 6.2 and version 2',async()=>{
 const xml=await read('tool/com.mxjxn.GenerantOsc.xrnx/manifest.xml');
 assert.match(xml,/<ApiVersion>6\.2<\/ApiVersion>/);assert.match(xml,/<Version>2<\/Version>/);assert.match(xml,/<Id>com\.mxjxn\.GenerantOsc<\/Id>/);
});

test('tool implements tracker, automation, export, and song mappings',async()=>{
 const lua=await read('tool/com.mxjxn.GenerantOsc.xrnx/main.lua');
 for(const phrase of ['^%[OSC%]','visible_effect_columns','pattern_track.automation','rack-osc-score','song().tool_data','/generant/v1/transport/tempo'])assert.ok(lua.includes(phrase),phrase);
});

test('documentation pages are HTML and do not link raw Markdown',async()=>{
 const pages=['docs/index.html',...(await readdir(new URL('docs/reference/',root))).filter(x=>x.endsWith('.html')).map(x=>'docs/reference/'+x)];
 for(const page of pages){const html=await read(page);assert.match(html,/<!doctype html>/i);assert.doesNotMatch(html,/href="[^"#]+\.md/);}
});
