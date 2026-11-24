(function(root){
  const punctuation=/[\p{P}\p{S}]/u;
  const space=/^$|\s/u;
  const cjk=/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Bopomofo}\u3000-\u303f\u30fb\uff00-\uffef]/u;
  const lastChar=text=>{const chars=[...(text||'')];return chars.length?chars[chars.length-1]:'';};
  const firstChar=text=>[...(text||'')][0]||'';

  function flags(before,after,mark){
    const sBefore=space.test(before),sAfter=space.test(after);
    const pBefore=punctuation.test(before),pAfter=punctuation.test(after);
    const cBefore=cjk.test(before),cAfter=cjk.test(after);
    const left=!sAfter&&(!pAfter||sBefore||pBefore||cBefore);
    const right=!sBefore&&(!pBefore||sAfter||pAfter||cAfter);
    if(mark==='*')return {open:left,close:right,cjk:cBefore||cAfter};
    return {open:left&&(!right||pBefore||(pAfter&&cBefore)),close:right&&(!left||pAfter||(pBefore&&cAfter)),cjk:cBefore||cAfter};
  }

  function markedEmStrong(src,maskedSrc,prevChar){
    const run=/^(\*+|_+)/.exec(src);
    if(!run||run[1].length>3)return false;
    const mark=run[1][0],size=run[1].length;
    const opener=flags(lastChar(prevChar),firstChar(src.slice(size)),mark);
    if(!opener.open)return false;
    const masked=maskedSrc.slice(-src.length);
    const runs=mark==='*'?/\*+/g:/_+/g;
    runs.lastIndex=size;
    let match;
    while((match=runs.exec(masked))){
      if(match[0].length!==size||src.slice(match.index,match.index+size)!==match[0])continue;
      if(match.index===size)continue;
      const closer=flags(lastChar(src.slice(0,match.index)),firstChar(src.slice(match.index+size)),mark);
      if(!closer.close)continue;
      if(!opener.cjk&&!closer.cjk)return false;
      const raw=src.slice(0,match.index+size),text=raw.slice(size,-size);
      if(size===1)return {type:'em',raw,text,tokens:this.lexer.inlineTokens(text)};
      if(size===2)return {type:'strong',raw,text,tokens:this.lexer.inlineTokens(text)};
      const inner=raw.slice(1,-1);
      return {type:'em',raw,text:inner,tokens:[{type:'strong',raw:inner,text,tokens:this.lexer.inlineTokens(text)}]};
    }
    return false;
  }

  function markedTokenizer(marked){
    const original=marked.Tokenizer.prototype.emStrong;
    return {emStrong(src,maskedSrc,prevChar){return original.call(this,src,maskedSrc,prevChar)||markedEmStrong.call(this,src,maskedSrc,prevChar);}};
  }

  root.acdianEmphasis={flags,markedTokenizer};
})(typeof globalThis!=='undefined'?globalThis:window);
