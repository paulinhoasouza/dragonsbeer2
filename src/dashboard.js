// Pure date/aggregation functions: cents are integers; dates are local business dates.
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=v=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((v||0)/100);
const number=v=>new Intl.NumberFormat('pt-BR').format(v);
const names={day:'Dia',week:'Semana',month:'Mês',year:'Ano',all:'Todos',bar:'Bar',kitchen:'Cozinha'};
const methods={pix:'Pix',cash:'Dinheiro',credit:'Crédito',debit:'Débito'};
const date=s=>new Date(s+'T12:00:00Z');
const iso=d=>d.toISOString().slice(0,10);
export const dateLabel=s=>s.split('-').reverse().join('/');
export function shiftDay(s,n){const d=date(s);d.setUTCDate(d.getUTCDate()+n);return iso(d)}
export function presetRange(key,today){
 const year=Number(today.slice(0,4));
 const from={today,week:shiftDay(today,-6),days30:shiftDay(today,-29),month:today.slice(0,7)+'-01',year:year+'-01-01',years:(year-4)+'-01-01'}[key];
 if(!from)throw Error('Período inválido.');return {from,to:today,group:key==='years'?'year':key==='year'?'month':'day'};
}
function bucketKey(day,group){if(group==='year')return day.slice(0,4)+'-01-01';if(group==='month')return day.slice(0,7)+'-01';if(group==='week')return shiftDay(day,-((date(day).getUTCDay()+6)%7));return day}
export function series(daily,from,to,group){
 if(!['day','week','month','year'].includes(group)||!/^\d{4}-\d{2}-\d{2}$/.test(from)||!/^\d{4}-\d{2}-\d{2}$/.test(to)||!Number.isFinite(+date(from))||!Number.isFinite(+date(to))||to<from||(+date(to)-date(from))/86400000>3660)throw Error('Período inválido.');
 const values=new Map(daily.map(d=>[d.day,d])),buckets=new Map();
 for(let day=from;day<=to;day=shiftDay(day,1)){
  const key=bucketKey(day,group);if(!buckets.has(key))buckets.set(key,{key,from:day,to:day,cents:0,count:0});
  const b=buckets.get(key),v=values.get(day);b.to=day;b.cents+=Number(v?.cents||0);b.count+=Number(v?.count||0);
 }
 return [...buckets.values()];
}
export function ranked(products,sector='all',metric='quantity'){
 return products.filter(p=>sector==='all'||p.station===sector).slice().sort((a,b)=>Number(b[metric])-Number(a[metric])||Number(b.cents)-Number(a.cents)||a.name.localeCompare(b.name,'pt-BR')||a.product_id.localeCompare(b.product_id));
}
const btn=(act,text,id='',active)=>`<button type="button" data-act="${act}" data-id="${esc(id)}" ${active===true?'class="active" aria-pressed="true"':active===false?'aria-pressed="false"':''}>${text}</button>`;
function chart(points,group){
 const W=Math.max(760,Math.min(1800,points.length*24)),H=270,L=86,R=24,T=22,B=42,base=H-B,max=Math.max(100,...points.map(p=>p.cents))*1.12;
 const x=i=>L+(points.length===1?(W-L-R)/2:i*(W-L-R)/(points.length-1)),y=v=>base-v/max*(base-T);
 const path=points.map((p,i)=>`${i?'L':'M'}${x(i).toFixed(2)},${y(p.cents).toFixed(2)}`).join(' ');
 const ticks=[...new Set(Array.from({length:Math.min(6,points.length)},(_,i)=>Math.round(i*(points.length-1)/Math.max(1,Math.min(6,points.length)-1))))];
 const label=p=>group==='year'?p.key.slice(0,4):group==='month'?p.key.slice(5,7)+'/'+p.key.slice(0,4):dateLabel(p.from).slice(0,5);
 return `<div class="chart-scroll"><svg class="revenue-chart" viewBox="0 0 ${W} ${H}" style="min-width:${Math.min(W,900)}px" role="group" aria-label="Faturamento recebido por ${names[group].toLowerCase()}. Pontos interativos; tabela disponível abaixo.">
 ${[0,1,2,3,4].map(i=>{const v=max*i/4;return `<line x1="${L}" x2="${W-R}" y1="${y(v)}" y2="${y(v)}" class="chart-grid"/><text x="${L-10}" y="${y(v)+4}" text-anchor="end">${esc(money(v))}</text>`}).join('')}
 <path d="${path} L${x(points.length-1)},${base} L${x(0)},${base} Z" class="chart-area"/>
 <path d="${path}" class="chart-line"/>
 ${points.map((p,i)=>`<g role="button" tabindex="0" data-act="report-bucket" data-id="${i}" aria-label="${dateLabel(p.from)}${p.to!==p.from?' a '+dateLabel(p.to):''}: ${money(p.cents)}, ${p.count} comandas. Ver detalhes."><title>${dateLabel(p.from)} a ${dateLabel(p.to)} · ${money(p.cents)} · ${p.count} comandas</title><circle class="chart-hit" cx="${x(i)}" cy="${y(p.cents)}" r="11"/><circle class="chart-dot" cx="${x(i)}" cy="${y(p.cents)}" r="${points.length>90?2:4}"/></g>`).join('')}
 ${ticks.map(i=>`<text x="${x(i)}" y="${H-10}" text-anchor="middle">${label(points[i])}</text>`).join('')}</svg></div>`;
}
export function dashboardHTML({data,from,to,group,sector,metric,loading,error}){
 const daily=data?.daily||[],products=data?.products||[],total=daily.reduce((s,p)=>s+Number(p.cents),0),count=daily.reduce((s,p)=>s+Number(p.count),0),quantity=products.reduce((s,p)=>s+Number(p.quantity),0);
 const ranks=ranked(products,sector,metric),points=data?series(daily,from,to,group):[];
 const winner=(title,p,value)=>`<article class="card winner"><p class="eyebrow">${title}</p>${p?`<button type="button" class="winner-link" data-act="report-product" data-id="${esc(JSON.stringify([p.product_id,p.station]))}">${esc(p.name)} <span aria-hidden="true">↗</span></button><strong>${value==='cents'?money(p.cents):number(p.quantity)+' unidades'}</strong><small>${value==='cents'?number(p.quantity)+' unidades':money(p.cents)} · ${names[p.station]}</small>`:'<h3>Sem vendas</h3><small>Nenhum produto recebido no período.</small>'}</article>`;
 const sectorCents=s=>products.filter(p=>p.station===s).reduce((n,p)=>n+Number(p.cents),0),bar=sectorCents('bar'),kitchen=sectorCents('kitchen'),itemTotal=bar+kitchen;
 return `<section class="dashboard" aria-busy="${loading}"><div class="row between"><div><p class="eyebrow">VISÃO DO NEGÓCIO</p><h2>Dashboard de vendas</h2></div>${btn('report-reload','↻ Atualizar dados')}</div>
 <form id="report-form" class="report-filters"><label>De<input type="date" name="from" required value="${from}"></label><label>Até<input type="date" name="to" required value="${to}"></label><button class="primary" ${loading?'disabled':''}>Consultar período</button></form>
 <nav class="tabs report-presets" aria-label="Períodos rápidos">${[['today','Hoje'],['week','7 dias'],['days30','30 dias'],['month','Este mês'],['year','Este ano'],['years','5 anos']].map(([k,l])=>btn('report-preset',l,k)).join('')}</nav>
 ${loading?'<p role="status" class="notice">Atualizando o dashboard…</p>':''}${error?`<p role="alert" class="banner">${esc(error)} ${btn('report-reload','Tentar novamente')}</p>`:''}
 ${!data?'<div class="empty">Consulte um período para visualizar os recebimentos.</div>':`
 <p class="muted report-caption">${dateLabel(from)} a ${dateLabel(to)} · Pagamentos confirmados · Fuso de Cuiabá<br><small>Atualizado em ${esc(new Date(data.generated_at).toLocaleString('pt-BR',{timeZone:'America/Cuiaba'}))}. Contas abertas e itens cancelados não entram nas vendas.</small></p>
 <div class="metrics report-metrics"><div class="metric">Faturamento recebido<strong>${money(total)}</strong><small>No período selecionado</small></div><div class="metric">Comandas pagas<strong>${number(count)}</strong><small>Individuais e compartilhadas</small></div><div class="metric">Ticket médio<strong>${money(count?total/count:0)}</strong><small>Por comanda paga</small></div><div class="metric">Itens vendidos<strong>${number(quantity)}</strong><small>Unidades em comandas pagas</small></div></div>
 <div class="winner-grid">${winner('MAIS VENDIDO · GERAL',ranked(products)[0])}${winner('MAIS VENDIDO · BAR',ranked(products,'bar')[0])}${winner('MAIS VENDIDO · COZINHA',ranked(products,'kitchen')[0])}${winner('MAIOR FATURAMENTO',ranked(products,'all','cents')[0],'cents')}</div>
 <article class="card revenue-panel"><div class="row between"><div><h3>Evolução do faturamento</h3><p class="muted">Clique em um ponto para detalhar ou explorar o período.</p></div><div class="tabs compact" aria-label="Agrupar faturamento">${['day','week','month','year'].map(g=>btn('report-group',names[g],g,group===g)).join('')}</div></div>
 ${chart(points,group)}<small class="muted">Valores em reais · ${group==='week'?'Semanas começam na segunda-feira. ':''}Primeiro e último intervalos respeitam as datas selecionadas. Dias sem recebimentos aparecem com zero.</small>
 <details class="chart-data"><summary>Ver dados do gráfico em tabela (${points.length} períodos)</summary><div class="table-scroll"><table><thead><tr><th>Período</th><th>Comandas</th><th>Faturamento</th><th></th></tr></thead><tbody>${points.map((p,i)=>`<tr><td>${dateLabel(p.from)}${p.to===p.from?'':' a '+dateLabel(p.to)}</td><td>${number(p.count)}</td><td>${money(p.cents)}</td><td>${btn('report-bucket','Detalhes',i)}</td></tr>`).join('')}</tbody></table></div></details></article>
 <div class="dashboard-grid"><article class="card ranking-panel"><div class="row between"><h3>Ranking de produtos</h3><div class="tabs compact">${btn('report-metric','Quantidade','quantity',metric==='quantity')}${btn('report-metric','Faturamento','cents',metric==='cents')}</div></div><div class="tabs compact" aria-label="Filtrar ranking por setor">${['all','bar','kitchen'].map(s=>btn('report-sector',names[s],s,sector===s)).join('')}</div><p class="muted">${names[sector]} · Top 10 por ${metric==='cents'?'faturamento':'unidades vendidas'}. Clique para ver detalhes.</p><div class="rank-list">${ranks.slice(0,10).map((p,i)=>`<button type="button" class="rank-row" data-act="report-product" data-id="${esc(JSON.stringify([p.product_id,p.station]))}"><span class="rank-number">${String(i+1).padStart(2,'0')}</span><span class="rank-content"><span class="rank-title"><strong>${esc(p.name)}</strong><b>${metric==='cents'?money(p.cents):number(p.quantity)+' un.'}</b></span><span class="rank-track"><span style="width:${Math.max(1,Number(p[metric])/Math.max(1,Number(ranks[0][metric]))*100)}%"></span></span><small>${names[p.station]} · ${metric==='cents'?number(p.quantity)+' unidades':money(p.cents)}</small></span></button>`).join('')||'<div class="empty">Nenhum produto vendido neste setor e período.</div>'}</div></article>
 <div class="dashboard-side"><article class="card"><h3>Faturamento por setor</h3><p class="muted">Participação dos produtos no período.</p><div class="sector-donut" role="img" aria-label="Bar: ${money(bar)}. Cozinha: ${money(kitchen)}." style="--share:${itemTotal?bar/itemTotal*100:0}%;--empty:${itemTotal?'#8adc9f':'#25392e'}"><span>${money(itemTotal)}<small>em produtos</small></span></div><div class="sector-legend">${[['bar',bar],['kitchen',kitchen]].map(([s,v])=>`<div><span><i class="dot ${s}"></i>${names[s]}</span><strong>${money(v)}</strong><small>${itemTotal?(v/itemTotal*100).toFixed(1).replace('.',','):0}%</small></div>`).join('')}</div></article><article class="card"><h3>Formas de pagamento</h3>${(data.methods||[]).map(p=>`<div class="payment-method"><span>${methods[p.method]||esc(p.method)}<small>${p.count} comandas</small></span><strong>${money(p.cents)}</strong></div>`).join('')||'<p class="muted">Sem recebimentos.</p>'}</article></div></div>
 <article class="card"><div class="row between"><h3>Comandas recebidas</h3><span class="muted">${Math.min(100,count)} de ${number(count)} · mais recentes</span></div><div class="table-scroll"><table><thead><tr><th>Data</th><th>Mesa</th><th>Comanda</th><th>Forma</th><th>Valor</th></tr></thead><tbody>${(data.payments||[]).map(p=>`<tr><td>${esc(new Date(p.paid_at).toLocaleString('pt-BR',{timeZone:'America/Cuiaba'}))}</td><td>${esc(p.table_name)}</td><td>${esc(p.tab_name)}</td><td>${methods[p.method]||esc(p.method)}</td><td>${money(p.amount_cents)}</td></tr>`).join('')}</tbody></table></div>${!count?'<div class="empty">Nenhum recebimento neste período.</div>':''}<p class="muted">Os indicadores e gráficos usam todo o período. A lista mostra até 100 recebimentos; reduza as datas para consultar outros.</p></article>
 <div class="row report-export"><span class="muted">Exportar o período completo:</span>${btn('report-export','Gráfico em CSV','series')}${btn('report-export','Produtos em CSV · '+names[sector],'products')}</div>`}</section>`;
}
export function reportCSV(data,from,to,group,kind,sector,metric){
 const rows=kind==='products'?[['Produto','Setor','Quantidade','Faturamento (R$)'],...ranked(data.products,sector,metric).map(p=>[p.name,names[p.station],p.quantity,(p.cents/100).toFixed(2).replace('.',',')])]:[['De','Até','Comandas','Faturamento (R$)'],...series(data.daily,from,to,group).map(p=>[dateLabel(p.from),dateLabel(p.to),p.count,(p.cents/100).toFixed(2).replace('.',',')])];
 return '\uFEFF'+rows.map(r=>r.map(v=>'"'+String(v??'').replace(/^[\s]*[=+@\-]/,"'$&").replaceAll('"','""')+'"').join(';')).join('\r\n');
}
