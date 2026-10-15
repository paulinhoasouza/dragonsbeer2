const fmt=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(n/100);
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let products=[],cart={},category='Todos',method=null,screen='cart';
const $=id=>document.getElementById(id);
const rows=()=>Object.entries(cart).map(([id,quantity])=>({p:products.find(x=>x.id===id),quantity})).filter(x=>x.p&&x.quantity>0);
const sum=()=>rows().reduce((n,r)=>n+r.p.price_cents*r.quantity,0);
function draw(){
 const count=rows().reduce((n,r)=>n+r.quantity,0);
 $('summary').textContent=count+' itens • '+fmt(sum());
 $('view-cart').disabled=!count;
 const cats=['Todos',...new Set(products.map(p=>p.category))];
 $('categories').innerHTML=cats.map(c=>'<button data-category="'+esc(c)+'" class="'+(c===category?'selected':'')+'">'+esc(c)+'</button>').join('');
 $('products').innerHTML=products.filter(p=>category==='Todos'||p.category===category).map(p=>'<article class="product">'+(p.image?'<img src="'+esc(p.image)+'" alt="'+esc(p.name)+'" loading="lazy">':'<div class="fallback">'+(p.station==='bar'?'🍺':'🍔')+'</div>')+'<div class="details"><h2>'+esc(p.name)+'</h2><p>'+esc(p.description)+'</p><div class="buy"><span class="price">'+fmt(p.price_cents)+'</span><button data-add="'+esc(p.id)+'" aria-label="Adicionar '+esc(p.name)+'">+ Adicionar</button></div></div></article>').join('');
}
function dialog(){
 $('overlay').classList.add('open');
 if(screen==='cart'){
 $('dialog-content').innerHTML='<h2>Seu pedido</h2>'+rows().map(({p,quantity})=>'<div class="line"><div><strong>'+esc(p.name)+'</strong><br><span class="muted">'+fmt(p.price_cents*quantity)+'</span></div><div class="qty"><button data-minus="'+esc(p.id)+'" aria-label="Diminuir '+esc(p.name)+'">−</button><strong>'+quantity+'</strong><button data-add="'+esc(p.id)+'" aria-label="Aumentar '+esc(p.name)+'">+</button></div></div>').join('')+'<div class="line"><strong>Total</strong><strong>'+fmt(sum())+'</strong></div><div class="actions"><button data-close>Continuar comprando</button><button class="primary" data-next>Pagamento</button></div>';
 }else{
 $('dialog-content').innerHTML='<h2>Forma de pagamento</h2><p>Total: <strong>'+fmt(sum())+'</strong></p><div class="methods"><button data-method="card" class="'+(method==='card'?'selected':'')+'">💳 Cartão</button><button data-method="pix" class="'+(method==='pix'?'selected':'')+'">▦ Pix por QR Code</button></div><div class="notice"><strong>Integração em desenvolvimento.</strong><p>Nenhuma cobrança é feita nesta versão de testes. O pedido não é enviado ao bar ou à cozinha.</p></div><div class="actions"><button data-back>Voltar</button><button disabled>Confirmar e pagar</button></div>';
 }
}
document.addEventListener('click',e=>{
 const el=e.target.closest('button');if(!el)return;
 if(el.dataset.category!==undefined){category=el.dataset.category;draw()}
 if(el.dataset.add!==undefined){cart[el.dataset.add]=(cart[el.dataset.add]||0)+1;draw();if($('overlay').classList.contains('open'))dialog()}
 if(el.dataset.minus!==undefined){cart[el.dataset.minus]=Math.max(0,(cart[el.dataset.minus]||0)-1);draw();if(!rows().length){$('overlay').classList.remove('open');screen='cart'}else dialog()}
 if(el.id==='view-cart'){screen='cart';dialog()}
 if(el.hasAttribute('data-close'))$('overlay').classList.remove('open');
 if(el.hasAttribute('data-next')){screen='payment';dialog()}
 if(el.hasAttribute('data-back')){screen='cart';dialog()}
 if(el.dataset.method!==undefined){method=el.dataset.method;dialog()}
});
(async()=>{try{const res=await fetch('/api/kiosk/catalog',{cache:'no-store'});if(!res.ok)throw Error('Falha '+res.status);const data=await res.json();if(!Array.isArray(data.products))throw Error('Resposta inválida');products=data.products;draw();$('status').textContent=products.length?'':'Cardápio vazio. Consulte a equipe.'}catch(e){$('status').innerHTML='<div class="notice">Cardápio indisponível no momento. Verifique a conexão e a instalação da migração 06.</div>';console.error(e)}})();
