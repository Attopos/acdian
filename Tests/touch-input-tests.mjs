// Run with: node Tests/touch-input-tests.mjs
import assert from 'node:assert';
import { dashPrefixFix, compositionFix } from '../Resources/touch-input.js';
assert.strictEqual(dashPrefixFix('--- '),null,'Plain hyphens are left alone');
assert.deepStrictEqual(dashPrefixFix('—- '),{from:0,to:2,insert:'---'},'An em dash from "--" becomes hyphens');
assert.deepStrictEqual(dashPrefixFix('  —'),{from:2,to:3,insert:'--'},'Indented dashes are corrected in place');
assert.strictEqual(dashPrefixFix('中—文'),null,'A dash inside text is left alone');
assert.deepStrictEqual(compositionFix('测试zhong wen',11,'zhong wen','中文'),{from:2,to:11,insert:'中文'},'Pinyin left behind is replaced by the chosen word');
assert.strictEqual(compositionFix('测试中文',4,'zhong wen','中文'),null,'A word committed correctly is left alone');
assert.strictEqual(compositionFix('abc',3,'',''),null,'No composition, no change');
assert.deepStrictEqual(compositionFix('abz',3,'z',''),{from:2,to:3,insert:''},'A deleted composition leaves no pinyin behind');
console.log('Touch input: dash and composition checks passed');
