/* Geometry and project data. All model coordinates are millimetres. */
(function (root) {
  'use strict';
  var types = {wall:'Tường',door:'Cửa đi',window:'Cửa sổ',floor:'Sàn',furniture:'Nội thất',dimension:'Kích thước'};
  var furniture = {
    table:{name:'Bàn 2 ghế',w:850,d:700,h:750,c:'#b58453'},
    dining:{name:'Bàn 4 ghế',w:1350,d:760,h:750,c:'#b58453'},
    counter:{name:'Quầy pha chế',w:2800,d:650,h:1050,c:'#7d8b72'},
    cabinet:{name:'Tủ gỗ',w:1400,d:450,h:2100,c:'#ac815d'},
    sofa:{name:'Ghế băng',w:1650,d:700,h:780,c:'#739184'},
    planter:{name:'Chậu cây',w:430,d:430,h:690,c:'#7c9766'}
  };
  var clone = function(v){return JSON.parse(JSON.stringify(v));};
  var dist = function(a,b){return Math.hypot(b[0]-a[0],b[1]-a[1]);};
  var mid = function(a,b){return [(a[0]+b[0])/2,(a[1]+b[1])/2];};
  var add = function(a,b){return [a[0]+b[0],a[1]+b[1]];};
  var sub = function(a,b){return [a[0]-b[0],a[1]-b[1]];};
  var mul = function(a,n){return [a[0]*n,a[1]*n];};
  var dot = function(a,b){return a[0]*b[0]+a[1]*b[1];};
  var round = function(v){return Number(v.toFixed(3));};
  var signArea = function(p){return p.reduce(function(total,a,i){
    var b=p[(i+1)%p.length];return total+a[0]*b[1]-b[0]*a[1];
  },0)/2;};
  function validPolygon(p){
    if(p.length<3||Math.abs(signArea(p))<100)return false;
    function crosses(a,b,c,d){
      function cross(p,q,r){return (q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0]);}
      function on(p,q,r){return r[0]>=Math.min(p[0],q[0])&&r[0]<=Math.max(p[0],q[0])&&r[1]>=Math.min(p[1],q[1])&&r[1]<=Math.max(p[1],q[1]);}
      var y=cross(a,b,c),z=cross(a,b,d),u=cross(c,d,a),v=cross(c,d,b);
      return (y*z<0&&u*v<0)||(y===0&&on(a,b,c))||(z===0&&on(a,b,d))||(u===0&&on(c,d,a))||(v===0&&on(c,d,b));
    }
    return p.every(function(a,i){var b=p[(i+1)%p.length];if(dist(a,b)<10)return false;
      return p.every(function(c,j){return j<=i+1||(i===0&&j===p.length-1)||!crosses(a,b,c,p[(j+1)%p.length]);});
    });
  }
  function wallFrame(w){
    var length=dist(w.a,w.b), dir=mul(sub(w.b,w.a),1/(length||1));
    return {length:length,dir:dir,n:[-dir[1],dir[0]],
      point:function(x,y){return add(w.a,add(mul(dir,x),mul([-dir[1],dir[0]],y||0)));}};
  }
  function wallOpenings(plan, id, excluded){
    return plan.items.filter(function(o){return o.wall===id&&o.id!==excluded;}).sort(function(a,b){return a.at-b.at;});
  }
  function joins(plan){
    var nodes={}, result={};
    plan.items.filter(function(o){return o.type==='wall';}).forEach(function(w){
      var v=wallFrame(w), open=wallOpenings(plan,w.id);
      var extents=open.length?[open[0].at-open[0].w/2,v.length-open[open.length-1].at-open[open.length-1].w/2]:[v.length,v.length];
      [w.a,w.b].forEach(function(p,i){
        var key=p.join(',');
        if(!nodes[key])nodes[key]=[];
        nodes[key].push({w:w,i:i,v:i?mul(v.dir,-1):v.dir,space:extents[i]});
      });
    });
    Object.keys(nodes).forEach(function(key){
      var pair=nodes[key];if(pair.length!==2)return;
      var a=pair[0],b=pair[1], cross=a.v[0]*b.v[1]-a.v[1]*b.v[0];
      if(a.w.t!==b.w.t||a.w.h!==b.w.h||Math.abs(cross)<.001)return;
      var k=(1+dot(a.v,b.v))/cross;
      if(Math.abs(k)>2.5||Math.abs(k)*a.w.t/2+1>=Math.min(a.space,b.space))return;
      if(!result[a.w.id])result[a.w.id]=[0,0];
      if(!result[b.w.id])result[b.w.id]=[0,0];
      result[a.w.id][a.i]=k;result[b.w.id][b.i]=-k;
    });
    return result;
  }
  function openingError(plan,o){
    var w=plan.items.find(function(x){return x.id===o.wall&&x.type==='wall';});
    if(!w)return 'Chọn một tường để đặt cửa.';
    var lo=o.at-o.w/2,hi=o.at+o.w/2;
    if(lo<-.001||hi>dist(w.a,w.b)+.001)return 'Ô mở vượt khỏi đầu tường.';
    if(o.sill+o.h>w.h+.001)return 'Chiều cao ô mở vượt khỏi tường.';
    if(wallOpenings(plan,w.id,o.id).some(function(x){return lo<x.at+x.w/2-.001&&hi>x.at-x.w/2+.001;}))return 'Ô mở bị chồng lên cửa khác.';
    return '';
  }
  function cabinetParts(o) {
    var w=o.w,d=o.d,h=o.h, t=Math.min(18,w/8,d/8,h/8), left=-w/2, back=-d/2;
    return [
      [left,back,0,t,d,h],[w/2-t,back,0,t,d,h],
      [left+t,back,0,w-2*t,d,t],[left+t,back,h-t,w-2*t,d,t],
      [left+t,back,t,w-2*t,t,h-2*t],[left+t,back+t,h/2,w-2*t,d-t,t]
    ];
  }
  function furnitureParts(o){
    var w=o.w,d=o.d,h=o.h,x=-w/2,y=-d/2,t=Math.min(45,w*.1,d*.1,h*.1);
    if(o.kind==='cabinet')return cabinetParts(o);
    if(o.kind==='counter')return [[x,y,0,w,d,h-t],[x-t*.35,y-t*.35,h-t,w+t*.7,d+t*.7,t]];
    if(o.kind==='sofa')return [[x,y,0,w,d,h*.56],[x,y,h*.56,w,d*.21,h*.44],
      [x,y+d*.21,h*.56,w*.09,d*.79,h*.25],[w*.41,y+d*.21,h*.56,w*.09,d*.79,h*.25]];
    if(o.kind==='planter')return [[x,y,0,w,d,h*.44],[-w*.32,-d*.32,h*.44,w*.64,d*.64,h*.56]];
    var parts=[[x,y,h-t,w,d,t]];
    [-1,1].forEach(function(sx){[-1,1].forEach(function(sy){
      parts.push([sx*(w/2-2*t)-t/2,sy*(d/2-2*t)-t/2,0,t,t,h-t]);
    });});
    chairRectangles(o).forEach(function(c){
      var seat=h*.56;
      parts.push([c[0],c[1],seat*.85,c[2],c[3],seat*.15]);
      parts.push([c[0],c[4]===1?c[1]+c[3]-t:c[1],seat,c[2],t,h*.44]);
      [0,1].forEach(function(ix){[0,1].forEach(function(iy){
        parts.push([c[0]+ix*(c[2]-t),c[1]+iy*(c[3]-t),0,t,t,seat*.85]);
      });});
    });
    return parts;
  }
  function chairRectangles(o){
    if(o.kind!=='table'&&o.kind!=='dining')return [];
    var c=Math.min(410,o.d*.78,o.w/(o.kind==='dining'?3:1.4)),out=[];
    (o.kind==='dining'?[-o.w*.25,o.w*.25]:[0]).forEach(function(cx){
      out.push([cx-c/2,-o.d/2-c+60,c,c,-1],[cx-c/2,o.d/2-60,c,c,1]);
    });
    return out;
  }
  function dimension(o, primitives){
    var len=dist(o.a,o.b);
    if(len<10)return;
    var v=mul(sub(o.b,o.a),1/len), n=[-v[1],v[0]], gap=o.offset,h=80;
    var a=add(o.a,mul(n,gap)), b=add(o.b,mul(n,gap)), direction=gap<0?-1:1;
    var lift=mul(n,direction*80), shift=mul(n,-direction*55), end1=add(a,lift), end2=add(b,lift);
    var angle=Math.atan2(v[1],v[0])*180/Math.PI;
    if(angle>90)angle-=180; if(angle<-90)angle+=180;
    var center=add(mid(a,b),shift), tick=mul(add(v,n),h*.5);
    var color='#45635e';
    [[o.a,end1],[o.b,end2],[a,b],[sub(a,tick),add(a,tick)],[sub(b,tick),add(b,tick)]].forEach(function(pts){
      primitives.push({t:'line',p:pts,s:color,sw:12,l:'DIM',id:o.id});
    });
    primitives.push({t:'text',a:center,text:String(Math.round(len)),size:155,angle:angle,s:color,l:'DIM',id:o.id,back:true});
  }
  function scene(plan, mono){
    var out=[];
    function primitive(o,t,p,s,f,l,sw){out.push({id:o.id,t:t,p:p,s:s,f:f,l:l,sw:sw||14});}
    function rect(fn,x,y,w,h){return [fn(x,y),fn(x+w,y),fn(x+w,y+h),fn(x,y+h)];}
    function label(o,a,text,size,l){
      out.push({id:o.id,t:'text',a:a,text:text,size:size,angle:0,s:mono?'#1d2423':'#273f35',l:l});
    }
    var by={}, cuts={}, joint=joins(plan);plan.items.forEach(function(o){
      by[o.id]=o;if(o.wall){if(!cuts[o.wall])cuts[o.wall]=[];cuts[o.wall].push(o);}
    });
    var rank={floor:0,wall:1,window:2,door:3,furniture:4,dimension:5};
    plan.items.slice().sort(function(a,b){return rank[a.type]-rank[b.type];}).forEach(function(o){
      if(o.type==='wall'){
        var f=wallFrame(o), t=o.t/2, start=0, angles=joint[o.id]||[0,0];
        var gaps=(cuts[o.id]||[]).sort(function(a,b){return a.at-b.at;}).concat([{at:f.length,w:0}]);
        function wallPoint(x,y){
          if(Math.abs(x)<.001)return f.point(x+y*angles[0],y);
          if(Math.abs(x-f.length)<.001)return f.point(x+y*angles[1],y);
          return f.point(x,y);
        }
        gaps.forEach(function(g){var end=g.at-g.w/2;
          if(end-start>.01)primitive(o,'poly',rect(wallPoint,start,-t,end-start,o.t),'#31433d',mono?'#333a38':o.c,'WALL',17);
          start=g.at+g.w/2;});
      }else if(o.type==='door'||o.type==='window'){
        var w=by[o.wall];if(!w)return;
        var frame=wallFrame(w),x=o.at-o.w/2,x2=o.at+o.w/2,side=w.t/2;
        var ink=mono?'#323a37':'#2c6a75';
        [x,x2].forEach(function(px){primitive(o,'line',[frame.point(px,-side),frame.point(px,side)],ink,null,'OPENING',15);});
        if(o.type==='window'){
          [-side*.34,side*.34].forEach(function(py){primitive(o,'line',[frame.point(x,py),frame.point(x2,py)],ink,null,'OPENING',16);});
        }else{
          var start=o.flip?x2:x, end=o.flip?x:x2, direction=o.flip?-1:1, swing=o.swing?-1:1;
          var arc=[];
          for(var i=0;i<=16;i++){var r=i*Math.PI/32;arc.push(frame.point(start+direction*o.w*Math.cos(r),swing*o.w*Math.sin(r)));}
          primitive(o,'line',arc,ink,null,'OPENING',13);
          primitive(o,'line',[frame.point(start,0),frame.point(start,swing*o.w)],ink,null,'OPENING',17);
          primitive(o,'line',[frame.point(start,0),frame.point(end,0)],ink,null,'OPENING',8);
        }
      }else if(o.type==='floor'){
        primitive(o,'poly',o.p,mono?'#909692':'#8e876a',mono?null:o.c,'FLOOR',13);
        var center=polygonLabel(o.p);
        label(o,center,o.name,200,'ROOM');
        label(o,[center[0],center[1]+250],(Math.abs(signArea(o.p))/1000000).toFixed(2)+' m²',145,'ROOM');
      }else if(o.type==='furniture'){
        var rad=o.angle*Math.PI/180, co=Math.cos(rad),si=Math.sin(rad);
        var world=function(x,y){return [o.a[0]+x*co-y*si,o.a[1]+x*si+y*co];};
        var fc=mono?'#f7f8f7':o.c, border=mono?'#333a38':'#4e5140';
        chairRectangles(o).forEach(function(c){primitive(o,'poly',rect(world,c[0],c[1],c[2],c[3]),border,mono?'#fff':'#e0c59d','FURNITURE',13);});
        if(o.kind==='planter'){
          var points=[];for(var k=0;k<24;k++){var a=k*Math.PI/12;points.push(world(o.w*Math.cos(a)/2,o.d*Math.sin(a)/2));}
          primitive(o,'poly',points,border,fc,'FURNITURE',15);
          for(var f=0;f<6;f++){var ar=f*Math.PI/3;primitive(o,'line',[o.a,world(o.w*Math.cos(ar)*.35,o.d*Math.sin(ar)*.35)],border,null,'FURNITURE',10);}
        }else{
          primitive(o,'poly',rect(world,-o.w/2,-o.d/2,o.w,o.d),border,fc,'FURNITURE',15);
          if(o.kind==='sofa')primitive(o,'line',[world(-o.w/2,-o.d*.29),world(o.w/2,-o.d*.29)],border,null,'FURNITURE',13);
          if(o.kind==='cabinet'||o.kind==='counter'){
            [-.25,0,.25].forEach(function(ratio){primitive(o,'line',[world(o.w*ratio,-o.d/2),world(o.w*ratio,o.d/2)],border,null,'FURNITURE',10);});
          }
        }
      }else if(o.type==='dimension'){dimension(o,out);}
    });
    if(mono)out.forEach(function(p){if(p.l==='DIM')p.s='#292f2c';});
    return out;
  }
  function polygonLabel(p) {
    var box=bounds(p), y=(box.minY+box.maxY)/2, rows=[y,y+.12*(box.maxY-box.minY),y-.12*(box.maxY-box.minY)];
    var best={len:-1,p:p[0]};
    rows.forEach(function(row){
      var xs=[];
      p.forEach(function(a,i){var b=p[(i+1)%p.length];if((a[1]>row)!==(b[1]>row))xs.push(a[0]+(b[0]-a[0])*(row-a[1])/(b[1]-a[1]));});
      xs.sort(function(a,b){return a-b;});
      for(var i=0;i<xs.length-1;i+=2){if(xs[i+1]-xs[i]>best.len)best={len:xs[i+1]-xs[i],p:[(xs[i]+xs[i+1])/2,row]};}
    });
    return best.p;
  }
  function bounds(points){
    if(!points.length)return {minX:0,minY:0,maxX:10000,maxY:7500};
    return points.reduce(function(box,p){
      box.minX=Math.min(box.minX,p[0]);box.minY=Math.min(box.minY,p[1]);
      box.maxX=Math.max(box.maxX,p[0]);box.maxY=Math.max(box.maxY,p[1]);
      return box;
    },{minX:Infinity,minY:Infinity,maxX:-Infinity,maxY:-Infinity});
  }
  function scenePoints(primitives){
    return primitives.reduce(function(pts,p){
      if(p.p){p.p.forEach(function(v){pts.push(v);});return pts;}
      var width=p.text.length*p.size*.32, height=p.size*.7, r=(p.angle||0)*Math.PI/180;
      [[-width,-height],[-width,height],[width,-height],[width,height]].forEach(function(v){
        pts.push(add(p.a,[v[0]*Math.cos(r)-v[1]*Math.sin(r),v[0]*Math.sin(r)+v[1]*Math.cos(r)]));
      });return pts;
    },[]);
  }
  var api={types:types,furniture:furniture,clone:clone,dist:dist,mid:mid,add:add,sub:sub,mul:mul,dot:dot,round:round,
    signArea:signArea,validPolygon:validPolygon,wallFrame:wallFrame,wallOpenings:wallOpenings,
    openingError:openingError,scene:scene,scenePoints:scenePoints,bounds:bounds,furnitureParts:furnitureParts};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
  else root.Plan=api;
})(typeof window!=='undefined'?window:this);
