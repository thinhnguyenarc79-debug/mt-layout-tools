(function () {
  'use strict';
  var P=window.Plan, $=function(id){return document.getElementById(id);};
  var SVG='http://www.w3.org/2000/svg', draw=$('drawing');
  var plan={v:1,name:'Mặt bằng mới',items:[],watermark:0};
  var active='select', selected=null, mono=false, pending=[], hover=null, move=null, pan=null;
  var mode='table', wallPreset={t:180,h:3300,c:'#627767'}, floorPreset={name:'Phòng',t:100,c:'#eee1c5'};
  var doorPreset={w:900,h:2200,sill:0,flip:false,swing:false}, windowPreset={w:1200,h:1300,sill:900};
  var dimOffset=420, undo=[], redo=[], uid=0, dirty=false, busy=false, stored=false, submitted=null;
  var view={x:5500,y:4000,k:12}, toast;
  var tools={select:'Chọn',wall:'Tường',door:'Cửa đi',window:'Cửa sổ',floor:'Sàn / phòng',
    furniture:'Nội thất',dimension:'Kích thước',pan:'Kéo khung'};
  var hints={select:'Bấm để chọn. Kéo để dời nội thất hoặc cửa. Delete để xóa.',
    wall:'Bấm điểm đầu và điểm tiếp theo. Escape để ngắt chuỗi.',
    door:'Bấm vào tường để đặt cửa đi. Chỉnh chiều mở bên phải.',
    window:'Bấm vào tường để đặt cửa sổ.',floor:'Bấm các góc theo thứ tự. Enter hoặc bấm lại góc đầu để khép vùng.',
    furniture:'Chọn mẫu ở cột phải, rồi bấm vào mặt bằng.',
    dimension:'Chọn hai điểm, rồi bấm điểm thứ ba để đặt đường dim.',
    pan:'Kéo để di chuyển khung nhìn. Cuộn chuột để zoom.'};
  var keyTools={v:'select',w:'wall',d:'door',o:'window',f:'floor',b:'furniture',m:'dimension',h:'pan'};
  function notify(message, error){
    var n=$('notice');n.textContent=message;n.className=error?'error':'';n.hidden=false;
    clearTimeout(toast);toast=setTimeout(function(){n.hidden=true;},5000);
  }
  function item(id){return plan.items.find(function(o){return o.id===id;});}
  function activeItem(){return item(selected);}
  function kindName(o){return o.name||P.types[o.type];}
  function setTool(k){
    active=k; pending=[];hover=null;move=null;selected=null;
    draw.dataset.tool=k;
    Array.prototype.forEach.call($('tools').querySelectorAll('button'),function(b){b.classList.toggle('active',b.dataset.tool===k);b.setAttribute('aria-pressed',String(b.dataset.tool===k));});
    $('hint').textContent=hints[k];refresh();
  }
  function saveState(){ $('save-state').textContent=dirty?'Có thay đổi':stored?'Đã lưu vào model':''; }
  function commit(fn){
    var before=P.clone(plan);
    try{
      fn();
      syncDimensions();
      if(JSON.stringify(plan)===JSON.stringify(before))return true;
      undo.push(before);if(undo.length>80)undo.shift();redo=[];dirty=true;saveState();refresh();return true;
    }catch(e){plan=before;notify(e.message,true);refresh();return false;}
  }
  function stepHistory(from,to){
    if(!from.length)return;
    to.push(P.clone(plan));plan=from.pop();selected=item(selected)?selected:null;pending=[];dirty=true;
    $('project-name').value=plan.name;saveState();refresh();
  }
  function syncDimensions(){
    function resolve(ref,fallback){
      if(!ref)return fallback;
      var o=item(ref.id);
      if(!o)return fallback;
      return ref.k==='p'?o.p[ref.i]||fallback:o[ref.k]||fallback;
    }
    plan.items.forEach(function(o){if(o.type==='dimension'){o.a=resolve(o.ra,o.a).slice();o.b=resolve(o.rb,o.b).slice();}});
  }
  function nextId(){uid=Math.max(uid,plan.watermark||0)+1;plan.watermark=uid;return 'p'+uid;}
  function addItem(type, values, append){
    commit(function(){
      if(plan.items.length>=1200)throw Error('Mặt bằng đã đạt 1.200 đối tượng.');
      var o=Object.assign({id:nextId(),type:type},P.clone(values));
      if(type==='door'||type==='window'){
        var error=P.openingError(plan,o);if(error)throw Error(error);
      }
      plan.items.push(o);if(!append)selected=o.id;
    });
  }
  function remove(){
    if(!activeItem())return;
    var id=selected;
    commit(function(){
      var removed=[id];
      plan.items=plan.items.filter(function(o){if(o.wall===id)removed.push(o.id);return o.id!==id&&o.wall!==id;});
      plan.items.forEach(function(o){if(o.type==='dimension'){if(o.ra&&removed.indexOf(o.ra.id)>=0)delete o.ra;if(o.rb&&removed.indexOf(o.rb.id)>=0)delete o.rb;}});
      selected=null;
    });
  }
  function svg(tag,attrs){
    var n=document.createElementNS(SVG,tag);
    Object.keys(attrs).forEach(function(k){n.setAttribute(k,attrs[k]);});return n;
  }
  function attrPoints(p){return p.map(function(q){return q.join(',');}).join(' ');}
  function paintShape(parent,p,isSelected,preview){
    var stroke=isSelected?'#0a936f':p.s, el;
    if(p.t==='text'){
      el=svg('text',{x:p.a[0],y:p.a[1],fill:stroke,'font-size':p.size,'text-anchor':'middle',
        'dominant-baseline':'central','font-weight':p.l==='ROOM'?620:550});
      if(p.angle)el.setAttribute('transform','rotate('+p.angle+' '+p.a[0]+' '+p.a[1]+')');
      if(p.back){el.style.stroke='#fafaf4';el.style.strokeWidth=String(p.size*.2);el.style.paintOrder='stroke';}
      el.textContent=p.text;
    }else{
      el=svg(p.t==='poly'?'polygon':'polyline',{points:attrPoints(p.p),stroke:stroke,
        fill:p.f||'none','stroke-width':isSelected?Math.max(25,p.sw):p.sw,
        'stroke-linecap':'round','stroke-linejoin':'round'});
    }
    if(p.id)el.dataset.id=p.id;
    if(preview)el.setAttribute('opacity',.68);
    parent.appendChild(el);
  }
  function viewingBox(){
    var w=Math.max(1,draw.clientWidth)*view.k,h=Math.max(1,draw.clientHeight)*view.k;
    var x=view.x-w/2,y=view.y-h/2;
    draw.setAttribute('viewBox',[x,y,w,h].join(' '));
    var bg=$('background');bg.setAttribute('x',x);bg.setAttribute('y',y);bg.setAttribute('width',w);bg.setAttribute('height',h);
  }
  function fit(){
    var box=P.bounds(P.scenePoints(P.scene(plan,mono)));
    view.x=(box.minX+box.maxX)/2;view.y=(box.minY+box.maxY)/2;
    view.k=Math.min(350,Math.max(.35,(box.maxX-box.minX+900)/Math.max(1,draw.clientWidth),
      (box.maxY-box.minY+900)/Math.max(1,draw.clientHeight)));viewingBox();
  }
  function render(){
    var root=$('objects');root.textContent='';
    P.scene(plan,mono).forEach(function(p){paintShape(root,p,p.id===selected,false);});
    renderGuide();
  }
  function renderGuide(){
    var g=$('guide');g.textContent='';
    if(!hover||active==='select'||active==='pan')return;
    var p=hover.p, r=Math.max(18,view.k*3.8), points=pending.map(function(q){return q.p;});
    g.appendChild(svg('circle',{cx:p[0],cy:p[1],r:r,stroke:'#127554','stroke-width':view.k*.8,fill:'#f4fff7'}));
    if((active==='wall'||active==='floor'||active==='dimension')&&points.length){
      var chain=points.concat([p]);
      if(active==='dimension'&&points.length===2){
        var off=offsetAt(points[0],points[1],p);
        P.scene({items:[{type:'dimension',a:points[0],b:points[1],offset:off}]},mono).forEach(function(q){paintShape(g,q,false,true);});return;
      }
      g.appendChild(svg('polyline',{points:attrPoints(chain),fill:'none',stroke:'#0d8c66',
        'stroke-width':Math.max(view.k,active==='wall'?wallPreset.t*.55:view.k*1.5),'stroke-linejoin':'round','stroke-linecap':'round'}));
      var a=points[points.length-1],mid=P.mid(a,p);
      paintShape(g,{t:'text',a:[mid[0],mid[1]-view.k*11],text:Math.round(P.dist(a,p))+' mm',s:'#176d53',
        size:view.k*12,back:true},false,true);
    }else if(active==='door'||active==='window'){
      if(hover.wall){
        var def=active==='door'?doorPreset:windowPreset;
        var ghost=Object.assign({type:active,id:'ghost',wall:hover.wall.id,at:hover.at},def);
        P.scene({items:[hover.wall,ghost]},mono).filter(function(q){return q.id==='ghost';})
          .forEach(function(q){if(P.openingError(plan,ghost))q.s='#ae3f33';paintShape(g,q,false,true);});
      }
    }else if(active==='furniture'){
      P.scene({items:[newFurniture(p)]},mono).forEach(function(q){paintShape(g,q,false,true);});
    }
  }
  function newFurniture(p){
    var f=P.furniture[mode];return {type:'furniture',kind:mode,name:f.name,a:p,angle:0,w:f.w,d:f.d,h:f.h,c:f.c};
  }
  function selectId(id){selected=id||null;refresh();}

  function field(parent,title,value,opts,write){
    var label=document.createElement('label'),input,choices=opts.choices;
    label.appendChild(document.createTextNode(title));if(opts.wide)label.classList.add('wide');
    if(choices){
      input=document.createElement('select');
      Object.keys(choices).forEach(function(k){var q=document.createElement('option');q.value=k;q.textContent=choices[k];input.appendChild(q);});
    }else{
      input=document.createElement('input');input.type=opts.type||'number';
      if(input.type==='number'){input.min=opts.min===undefined?-1000000:opts.min;input.max=opts.max===undefined?1000000:opts.max;input.step='any';}
      if(input.type==='text')input.maxLength=100;
      if(input.type==='checkbox')label.classList.add('tick');
    }
    if(input.type==='checkbox')input.checked=value;else input.value=value;
    var inputName=opts.key;if(inputName)input.dataset.field=inputName;
    input.addEventListener('change',function(){
      var val=input.type==='checkbox'?input.checked:input.value;
      if(input.type==='number'){
        if(!input.value||!input.validity.valid){input.value=value;notify('Nhập giá trị trong phạm vi cho phép.',true);return;}
        val=P.round(Number(val));
      }
      if(input.type==='text'){val=val.trim();if(!val){input.value=value;return;}}
      write(val);
    });
    label.appendChild(input);parent.appendChild(label);
  }
  function textLine(parent,line,cls){var p=document.createElement('p');p.className=cls||'note';p.textContent=line;parent.appendChild(p);}
  function validateDependents(o){
    if(o.type==='wall')P.wallOpenings(plan,o.id).forEach(function(g){var e=P.openingError(plan,g);if(e)throw Error(e);});
    if(o.type==='door'||o.type==='window'){var e=P.openingError(plan,o);if(e)throw Error(e);}
  }
  function inspector(){
    var o=activeItem(), box=$('inspector');box.textContent='';
    var title=o?kindName(o):active==='select'?'Mặt bằng':tools[active];
    $('inspector-title').textContent=title;$('inspector-kicker').textContent=o?P.types[o.type]:'Thông số';
    var grid=document.createElement('div');grid.className='field-grid';box.appendChild(grid);
    function put(label,k,val,opts,apply){opts.key=k;field(grid,label,val,opts,apply);}
    function bind(label,obj,k,opts){put(label,k,obj[k],opts,function(v){
      if(o){commit(function(){obj[k]=v;validateDependents(o);});}
      else {obj[k]=v;renderGuide();}
    });}
    function num(label,obj,k,min,max){bind(label,obj,k,{min:min,max:max});}
    function color(obj){bind('Màu vật liệu',obj,'c',{type:'color'});}
    function name(obj){bind('Tên',obj,'name',{type:'text',wide:true});}
    function check(label,obj,k){bind(label,obj,k,{type:'checkbox',wide:true});}
    function axis(o,key,index,label){
      put(label,key+index,o[key][index],{},function(v){commit(function(){
        if(o.type==='wall'){var delta=v-o.a[index];o.a[index]=v;o.b[index]=P.round(o.b[index]+delta);}
        else o[key][index]=v;
      });});
    }
    if(o){
      if(o.type==='wall'){
        var f=P.wallFrame(o),angle=Math.atan2(f.dir[1],f.dir[0])*180/Math.PI;
        num('Bề dày',o,'t',25,3000);num('Cao',o,'h',100,30000);
        axis(o,'a',0,'Đầu X');axis(o,'a',1,'Đầu Y');
        function wallShape(length,rotation){commit(function(){
          var a=rotation*Math.PI/180;o.b=[P.round(o.a[0]+Math.cos(a)*length),P.round(o.a[1]+Math.sin(a)*length)];validateDependents(o);
        });}
        put('Dài', 'length',P.round(f.length),{min:25,max:1000000},function(v){wallShape(v,angle);});
        put('Góc °','angle',P.round(angle),{min:-360,max:360},function(v){wallShape(f.length,v);});color(o);
      }else if(o.type==='door'||o.type==='window'){
        num('Rộng',o,'w',100,20000);num('Cao',o,'h',100,30000);
        num('Tâm cách đầu tường',o,'at',0,1000000);
        if(o.type==='window')num('Cao độ bậu',o,'sill',0,29900);
        else{check('Đổi phía bản lề',o,'flip');check('Đổi hướng mở',o,'swing');}
      }else if(o.type==='furniture'){
        name(o);num('Rộng',o,'w',100,30000);num('Sâu',o,'d',100,30000);
        num('Cao',o,'h',100,30000);num('Góc °',o,'angle',-360,360);
        axis(o,'a',0,'Tâm X');axis(o,'a',1,'Tâm Y');color(o);
      }else if(o.type==='floor'){
        name(o);num('Dày sàn',o,'t',10,3000);color(o);
        textLine(box,(Math.abs(P.signArea(o.p))/1e6).toFixed(2)+' m²','fact');
      }else if(o.type==='dimension'){
        num('Độ lệch đường dim',o,'offset',-1000000,1000000);
        textLine(box,Math.round(P.dist(o.a,o.b))+' mm','fact');
        if(o.ra||o.rb)textLine(box,'Điểm dim bám theo đối tượng đã bắt.');
      }
      var actions=document.createElement('div');actions.className='inspect-actions';
      if(o.type==='furniture'){
        var rotate=document.createElement('button');rotate.className='quiet';rotate.textContent='Xoay 90°';
        rotate.onclick=function(){commit(function(){o.angle=(o.angle+90)%360;});};actions.appendChild(rotate);
      }
      var del=document.createElement('button');del.className='quiet danger';del.textContent='Xóa';del.onclick=remove;actions.appendChild(del);box.appendChild(actions);
      return;
    }
    if(active==='wall'){num('Bề dày',wallPreset,'t',25,3000);num('Cao',wallPreset,'h',100,30000);color(wallPreset);}
    else if(active==='floor'){name(floorPreset);num('Dày sàn',floorPreset,'t',10,3000);color(floorPreset);}
    else if(active==='door'||active==='window'){
      var d=active==='door'?doorPreset:windowPreset;
      num('Rộng',d,'w',100,20000);num('Cao',d,'h',100,30000);
      if(active==='window')num('Cao độ bậu',d,'sill',0,29900);else{check('Đổi phía bản lề',d,'flip');check('Đổi hướng mở',d,'swing');}
    }else if(active==='furniture'){
      var choices={};Object.keys(P.furniture).forEach(function(k){choices[k]=P.furniture[k].name;});
      put('Mẫu','furnitureKind',mode,{choices:choices,wide:true},function(v){mode=v;renderGuide();});
    }else if(active==='dimension'){
      textLine(box,'Khi bắt vào đầu tường, đỉnh sàn hoặc tâm đồ, dim cập nhật cùng điểm đã bắt.');
    }else if(active==='select'){
      if(plan.items.length)textLine(box,'Chọn một đối tượng trên mặt bằng để sửa thông số.');
      else textLine(box,'Để dùng model SKP đang mở, chọn một Group hoặc Component trong SketchUp rồi vào Xuất bản vẽ → Ba hình chiếu.');
    }
  }
  function refresh(){
    render();inspector();var list=$('object-list'), y=list.scrollTop;list.textContent='';
    plan.items.forEach(function(o){
      var b=document.createElement('button');b.textContent=kindName(o)+' · '+o.id.slice(1);
      b.className=o.id===selected?'active':'';b.onclick=function(){if(active!=='select')setTool('select');selectId(o.id);};list.appendChild(b);
    });
    list.scrollTop=y;$('count').textContent=plan.items.length;
    var area=plan.items.reduce(function(total,o){return total+(o.type==='floor'?Math.abs(P.signArea(o.p))/1e6:0);},0);
    var furniture=plan.items.filter(function(o){return o.type==='furniture';}).length;
    $('stats').textContent=area.toFixed(2)+' m² sàn · '+furniture+' nhóm đồ';
    $('undo').disabled=!undo.length;$('redo').disabled=!redo.length;
  }
  function world(e){
    var bounds=draw.getBoundingClientRect();return [view.x+(e.clientX-bounds.left-bounds.width/2)*view.k,
      view.y+(e.clientY-bounds.top-bounds.height/2)*view.k];
  }
  function snapped(raw,skip){
    var q={p:raw.map(P.round)};if(!$('snap').checked)return q;
    var limit=Math.max(view.k*9,20),best=limit;
    function tryPoint(p,ref){var d=P.dist(raw,p);if(d<best){best=d;q={p:p.slice(),ref:ref};}}
    plan.items.forEach(function(o){
      if(o.id===skip)return;
      if(o.type==='wall'){tryPoint(o.a,{id:o.id,k:'a'});tryPoint(o.b,{id:o.id,k:'b'});}
      else if(o.type==='floor')o.p.forEach(function(p,i){tryPoint(p,{id:o.id,k:'p',i:i});});
      else if(o.type==='furniture')tryPoint(o.a,{id:o.id,k:'a'});
    });
    if(best===limit){
      var g=Number($('step').value);q.p=raw.map(function(n){return Math.round(n/g)*g;});
    }
    if(active==='floor'&&pending.length>=3&&P.dist(raw,pending[0].p)<limit)q.p=pending[0].p.slice();
    return q;
  }
  function nearestWall(raw, limit, id){
    var candidate=null,best=limit;
    plan.items.forEach(function(o){
      if(o.type!=='wall'||(id&&o.id!==id))return;
      var f=P.wallFrame(o),s=P.dot(P.sub(raw,o.a),f.dir),d=P.dist(raw,f.point(Math.max(0,Math.min(f.length,s)),0));
      if(d<=best+o.t/2){best=Math.max(0,d-o.t/2);var grid=Number($('step').value);
        candidate={wall:o,at:P.round($('snap').checked?Math.round(s/grid)*grid:s)};}
    });
    return candidate;
  }
  function offsetAt(a,b,p){
    var l=P.dist(a,b),v=P.sub(b,a);
    if(l<1)return dimOffset;
    var n=P.dot(P.sub(p,a),[-v[1]/l,v[0]/l]);
    return Math.abs(n)<65?(n<0?-dimOffset:dimOffset):P.round(n);
  }
  function finishFloor(){
    var corners=pending.map(function(q){return q.p;});
    if(!P.validPolygon(corners)){notify('Vùng sàn cần ít nhất 3 góc, không tự cắt.',true);return;}
    addItem('floor',Object.assign({},floorPreset,{p:corners}),false);pending=[];renderGuide();
  }
  function pointClick(raw){
    var q=snapped(raw);
    if(active==='wall'){
      if(!pending.length){pending=[q];return;}
      var a=pending[0].p;
      if(P.dist(a,q.p)<25){notify('Đoạn tường cần dài ít nhất 25 mm.',true);return;}
      var repeated=plan.items.some(function(w){return w.type==='wall'&&((P.dist(w.a,a)<1&&P.dist(w.b,q.p)<1)||(P.dist(w.b,a)<1&&P.dist(w.a,q.p)<1));});
      if(repeated){notify('Đã có tường trùng đoạn này.',true);return;}
      addItem('wall',Object.assign({a:a,b:q.p},wallPreset),true);pending=[q];
    }else if(active==='door'||active==='window'){
      var w=nearestWall(raw,Math.max(130,view.k*11));
      if(!w){notify('Bấm vào một đoạn tường để đặt ô mở.',true);return;}
      addItem(active,Object.assign({wall:w.wall.id,at:w.at},active==='door'?doorPreset:windowPreset),true);
    }else if(active==='floor'){
      if(pending.length>2&&P.dist(q.p,pending[0].p)<1){finishFloor();return;}
      if(pending.length>=400){notify('Khép vùng sàn hiện tại trước khi vẽ thêm.',true);return;}
      if(!pending.length||P.dist(pending[pending.length-1].p,q.p)>=10)pending.push(q);
    }else if(active==='furniture'){
      addItem('furniture',newFurniture(q.p),true);
    }else if(active==='dimension'){
      if(pending.length<2){if(!pending.length||P.dist(pending[0].p,q.p)>=10)pending.push(q);return;}
      var da=pending[0],db=pending[1],dim={a:da.p,b:db.p,offset:offsetAt(da.p,db.p,raw)};
      if(da.ref)dim.ra=da.ref;if(db.ref)dim.rb=db.ref;
      addItem('dimension',dim,false);pending=[];
    }
  }
  draw.addEventListener('pointerdown',function(e){
    if(e.button!==0&&e.button!==1)return;
    draw.focus();
    var raw=world(e);
    if(active==='pan'||e.button===1){
      e.preventDefault();pan={id:e.pointerId,at:[e.clientX,e.clientY],x:view.x,y:view.y};draw.setPointerCapture(e.pointerId);draw.classList.add('dragging');return;
    }
    if(active==='select'){
      var el=e.target.closest('[data-id]'), o=el?item(el.dataset.id):null;
      selectId(o&&o.id);
      if(o&&(o.type==='furniture'||o.type==='door'||o.type==='window')){
        move={id:e.pointerId,o:o,from:raw,start:o.a&&o.a.slice(),at:o.at,delta:[0,0],done:false};
        draw.setPointerCapture(e.pointerId);
      }
      return;
    }
    pointClick(raw);renderGuide();
  });
  draw.addEventListener('pointermove',function(e){
    if(pan){
      view.x=pan.x+(pan.at[0]-e.clientX)*view.k;view.y=pan.y+(pan.at[1]-e.clientY)*view.k;viewingBox();return;
    }
    var raw=world(e);hover=snapped(raw);$('coordinates').textContent='X '+Math.round(hover.p[0])+' · Y '+Math.round(hover.p[1])+' mm';
    if(move){
      var change=P.sub(raw,move.from);if(P.dist([0,0],change)<view.k*3&&!move.done)return;
      move.done=true; move.delta=change;
      if(move.start)move.o.a=snapped(P.add(move.start,change),move.o.id).p;
      else{var w=nearestWall(raw,Infinity,move.o.wall);if(w)move.o.at=w.at;}
      syncDimensions();render();return;
    }
    if(active==='door'||active==='window'){
      var near=nearestWall(raw,Math.max(130,view.k*11));if(near)Object.assign(hover,near);
    }
    renderGuide();
  });
  function endPointer(e,cancel){
    if(pan){pan=null;draw.classList.remove('dragging');}
    if(!move)return;
    var m=move;move=null;var place=m.o.a&&m.o.a.slice(),distance=m.o.at;
    if(m.start)m.o.a=m.start;else m.o.at=m.at;
    syncDimensions();
    if(!cancel&&m.done)commit(function(){if(m.start)m.o.a=place;else m.o.at=distance;validateDependents(m.o);});
    refresh();
  }
  draw.addEventListener('pointerup',function(e){endPointer(e,false);});
  draw.addEventListener('pointercancel',function(e){endPointer(e,true);});
  draw.addEventListener('pointerleave',function(){if(!pan&&!move){hover=null;renderGuide();}});
  function zoom(factor,e){
    var old=view.k, next=Math.max(.35,Math.min(350,old*factor));
    if(e){var point=world(e), ratio=next/old;view.x=point[0]+(view.x-point[0])*ratio;view.y=point[1]+(view.y-point[1])*ratio;}
    view.k=next;viewingBox();renderGuide();
  }
  draw.addEventListener('wheel',function(e){e.preventDefault();zoom(e.deltaY>0?1.15:1/1.15,e);},{passive:false});
  $('tools').addEventListener('click',function(e){var b=e.target.closest('[data-tool]');if(b)setTool(b.dataset.tool);});
  $('undo').onclick=function(){stepHistory(undo,redo);};$('redo').onclick=function(){stepHistory(redo,undo);};
  $('fit').onclick=fit;$('zoom-in').onclick=function(){zoom(.8);};$('zoom-out').onclick=function(){zoom(1.25);};
  $('color').onclick=function(){mono=false;viewStyle();};$('mono').onclick=function(){mono=true;viewStyle();};
  function viewStyle(){$('color').setAttribute('aria-pressed',String(!mono));$('mono').setAttribute('aria-pressed',String(mono));render();}
  $('project-name').onchange=function(){var input=$('project-name');commit(function(){plan.name=input.value.trim()||'Mặt bằng mới';});input.value=plan.name;};
  window.addEventListener('keydown',function(e){
    if(e.key==='Escape'){pending=[];hover=null;toggleExport(false);renderGuide();return;}
    if(/^(INPUT|SELECT|TEXTAREA)$/.test(e.target.tagName))return;
    var key=e.key.toLowerCase();
    if(e.ctrlKey||e.metaKey){
      if(key==='z'){e.preventDefault();if(e.shiftKey)stepHistory(redo,undo);else stepHistory(undo,redo);}
      if(key==='y'){e.preventDefault();stepHistory(redo,undo);}return;
    }
    if(key==='enter'&&active==='floor'&&pending.length&&e.target.tagName!=='BUTTON'){e.preventDefault();finishFloor();}
    else if(key==='delete'||key==='backspace'){e.preventDefault();remove();}
    else if(keyTools[key])setTool(keyTools[key]);
  });
  if(window.ResizeObserver)new ResizeObserver(viewingBox).observe(draw);else window.addEventListener('resize',viewingBox);
  function setPlan(data, replace){
    if(!data||data.v!==1||!Array.isArray(data.items))throw Error('Mặt bằng không tương thích.');
    if(replace){if(!commit(function(){plan=P.clone(data);}))return;}
    else{plan=P.clone(data);undo=[];redo=[];dirty=false;saveState();}
    uid=Math.max(uid,plan.watermark||0);
    $('project-name').value=plan.name;setTool('select');fit();
  }
  function toggleExport(open){$('exports').hidden=!open;$('export-toggle').setAttribute('aria-expanded',String(open));}
  $('export-toggle').onclick=function(){toggleExport($('exports').hidden);};
  function request(action,data){
    if(busy)return;
    var bridge=window.sketchup&&window.sketchup.mt_request;
    if(!bridge){notify('Mở plugin trong SketchUp để sử dụng lệnh này.',true);return;}
    busy=true;submitted=action==='save'||action==='build'?JSON.stringify(data.plan):null;
    try{window.sketchup.mt_request(action,JSON.stringify(data||{}));}
    catch(e){busy=false;submitted=null;notify('Không thể kết nối với SketchUp.',true);}
  }
  $('save').onclick=function(){request('save',{plan:plan});};
  $('build').onclick=function(){
    if(!plan.items.some(function(o){return o.type==='wall'||o.type==='floor'||o.type==='furniture';})){
      notify('Vẽ ít nhất một tường, sàn hoặc nội thất trước khi dựng.',true);return;
    }
    var parts={};plan.items.filter(function(o){return o.type==='furniture';}).forEach(function(o){parts[o.id]=P.furnitureParts(o);});
    request('build',{plan:plan,parts:parts});
  };
  $('save-file').onclick=function(){request('save_file',{plan:plan});};
  $('load-file').onclick=function(){request('load_file');};
  $('exports').addEventListener('click',function(e){
    var button=e.target.closest('[data-export]');if(!button)return;
    var format=button.dataset.export;
    if(format.indexOf('views_')!==0&&!plan.items.length){notify('Vẽ mặt bằng trước khi xuất.',true);return;}
    if(format==='csv'){toggleExport(false);request(format,{plan:plan});return;}
    var scene=format.indexOf('views_')===0?[]:P.scene(plan,$('sheet-mono').checked&&format==='pdf');
    var settings={name:plan.name,paper:$('paper-size').value,scale:Number($('scale').value),mono:$('sheet-mono').checked,scene:scene};
    toggleExport(false);request(format,settings);
  });
  window.MT={
    receive:function(r){
      busy=false;
      if(r.plan)setPlan(r.plan,Boolean(r.replace));
      if(r.saved){stored=true;if(!submitted||submitted===JSON.stringify(plan))dirty=false;saveState();}
      submitted=null;
      if(r.message)notify(r.message,Boolean(r.error));
    }
  };
  $('project-name').value=plan.name;saveState();setTool('select');fit();
  if(window.sketchup&&window.sketchup.mt_ready)window.sketchup.mt_ready();
})();
