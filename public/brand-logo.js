function brandLogoMarkup(sizeClass){
  return `<span class="rb-logo ${sizeClass}" aria-hidden="true"><span class="rb-logo-face"><span class="rb-logo-letter">R</span></span></span>`;
}

function renderBrandLogos(root=document){
  root.querySelectorAll('.rb-logo-slot[data-logo-size]').forEach(host=>{
    host.innerHTML=brandLogoMarkup(host.dataset.logoSize);
  });
  root.querySelectorAll('.rb-logo').forEach(logo=>{
    if(logo.dataset.motionReady||window.matchMedia('(prefers-reduced-motion: reduce)').matches)return;
    logo.dataset.motionReady='true';
    let resetTimer;
    const setTilt=event=>{
      const bounds=logo.getBoundingClientRect();
      const x=(event.clientX-bounds.left)/bounds.width-.5;
      const y=(event.clientY-bounds.top)/bounds.height-.5;
      logo.style.setProperty('--logo-tilt-x',`${Math.max(-14,Math.min(14,-y*25))}deg`);
      logo.style.setProperty('--logo-tilt-y',`${Math.max(-16,Math.min(16,x*30))}deg`);
    };
    const resetTilt=()=>{
      resetTimer=setTimeout(()=>{
        logo.style.setProperty('--logo-tilt-x','0deg');
        logo.style.setProperty('--logo-tilt-y','0deg');
      },160);
    };
    logo.addEventListener('pointerdown',event=>{
      clearTimeout(resetTimer);
      setTilt(event);
      if(event.pointerType==='touch')logo.setPointerCapture?.(event.pointerId);
    });
    logo.addEventListener('pointermove',setTilt);
    logo.addEventListener('pointerup',resetTilt);
    logo.addEventListener('pointercancel',resetTilt);
    logo.addEventListener('pointerleave',resetTilt);
  });
}
