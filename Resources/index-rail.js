// A vertical A–Z style index, like the letter rail in Contacts. It knows
// nothing about what it indexes: give it the group names and a callback.
//
//   const rail = createIndexRail({groups:['A','B'], active:'A', label:'Letters', onSelect:name => …});
//   container.append(rail.element); rail.setActive('B');
//
// Dragging along the rail selects each letter it passes, as on a phone.
// Styles live under .ac-index-rail in live-editor.css and light.css.
export function createIndexRail({groups, active=null, label='', onSelect}) {
  const element=document.createElement('nav');
  element.className='ac-index-rail';
  if(label)element.setAttribute('aria-label',label);
  const buttons=new Map();
  let current=null, dragging=false;
  const setActive=name=>{
    current=name;
    for(const [group,button] of buttons){const on=group===name;button.classList.toggle('active',on);button.setAttribute('aria-current',on?'true':'false');}
  };
  const choose=name=>{if(name&&name!==current){setActive(name);onSelect?.(name);}};
  for(const group of groups){
    const button=document.createElement('button');
    button.type='button';button.textContent=group;button.dataset.group=group;
    button.addEventListener('mousedown',event=>{event.preventDefault();dragging=true;choose(group);});
    button.addEventListener('mouseenter',()=>{if(dragging)choose(group);});
    button.addEventListener('click',event=>event.preventDefault());
    buttons.set(group,button);element.append(button);
  }
  const stop=()=>{dragging=false;};
  window.addEventListener('mouseup',stop);
  setActive(active);
  return {element,setActive,get active(){return current;},destroy(){window.removeEventListener('mouseup',stop);}};
}
