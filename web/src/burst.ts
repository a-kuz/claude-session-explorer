// Декоративная 3D-звезда Claude (SDF raymarch, WebGL2) в углу экрана.
// Порт ~/ws/shad/claude-burst-opt.html: два прохода — один раз печём знаковый
// дистанс полигона в float-текстуру, затем каждый кадр дешёвый raymarch.
// Настройки зашиты (режим idle: редкая волна пульсации), фон прозрачный,
// объект можно вращать мышью.

const VERT_SRC = `#version 300 es
in vec2 p; void main(){ gl_Position=vec4(p,0.0,1.0); }`;

// Проход 1: D0(p) базового полигона (112 вершин) → текстура, один раз при старте.
const BAKE_SRC = `#version 300 es
precision highp float;
out vec4 o;
uniform vec2 iSdfRes;
uniform vec2 iSdfHalf;
#define NP 112

const vec2 VERT[NP] = vec2[NP](
vec2(0.672,0.),vec2(0.408,0.057),vec2(0.844,0.164),vec2(0.881,0.203),vec2(0.891,0.239),vec2(0.87,0.266),vec2(0.809,0.295),vec2(0.702,0.284),vec2(0.297,0.185),vec2(0.26,0.182),vec2(0.286,0.216),vec2(0.562,0.472),vec2(0.653,0.568),vec2(0.694,0.625),vec2(0.681,0.657),vec2(0.658,0.658),vec2(0.556,0.596),vec2(0.262,0.361),vec2(0.474,0.73),vec2(0.471,0.783),vec2(0.46,0.797),vec2(0.431,0.811),vec2(0.396,0.811),vec2(0.343,0.77),vec2(0.308,0.726),vec2(0.061,0.345),vec2(0.048,0.389),vec2(0.013,0.764),vec2(-0.016,0.919),vec2(-0.033,0.937),vec2(-0.067,0.951),vec2(-0.099,0.944),vec2(-0.128,0.913),vec2(-0.11,0.697),vec2(-0.058,0.297),vec2(-0.279,0.599),vec2(-0.387,0.727),vec2(-0.462,0.8),vec2(-0.49,0.815),vec2(-0.523,0.805),vec2(-0.543,0.775),vec2(-0.425,0.586),vec2(-0.192,0.246),vec2(-0.559,0.486),vec2(-0.67,0.543),vec2(-0.698,0.546),vec2(-0.739,0.537),vec2(-0.76,0.512),vec2(-0.761,0.476),vec2(-0.723,0.435),vec2(-0.547,0.315),vec2(-0.226,0.12),vec2(-0.227,0.11),vec2(-0.31,0.101),vec2(-0.861,0.075),vec2(-0.911,0.064),vec2(-0.933,0.049),vec2(-0.952,0.017),vec2(-0.953,0.),vec2(-0.942,-0.017),vec2(-0.703,-0.025),vec2(-0.246,-0.017),vec2(-0.707,-0.33),vec2(-0.791,-0.403),vec2(-0.804,-0.427),vec2(-0.812,-0.469),vec2(-0.805,-0.503),vec2(-0.77,-0.539),vec2(-0.723,-0.545),vec2(-0.605,-0.473),vec2(-0.236,-0.213),vec2(-0.247,-0.247),vec2(-0.441,-0.585),vec2(-0.52,-0.743),vec2(-0.526,-0.78),vec2(-0.516,-0.826),vec2(-0.483,-0.871),vec2(-0.454,-0.89),vec2(-0.375,-0.883),vec2(-0.344,-0.85),vec2(-0.061,-0.289),vec2(-0.023,-0.187),vec2(-0.014,-0.199),vec2(0.037,-0.703),vec2(0.056,-0.799),vec2(0.089,-0.844),vec2(0.121,-0.86),vec2(0.15,-0.854),vec2(0.189,-0.818),vec2(0.196,-0.787),vec2(0.184,-0.641),vec2(0.113,-0.242),vec2(0.124,-0.243),vec2(0.148,-0.268),vec2(0.361,-0.535),vec2(0.475,-0.653),vec2(0.513,-0.681),vec2(0.537,-0.688),vec2(0.591,-0.68),vec2(0.638,-0.616),vec2(0.643,-0.6),vec2(0.625,-0.524),vec2(0.381,-0.194),vec2(0.317,-0.079),vec2(0.602,-0.128),vec2(0.781,-0.152),vec2(0.853,-0.15),vec2(0.882,-0.124),vec2(0.881,-0.093),vec2(0.869,-0.061),vec2(0.793,-0.028),vec2(0.728,-0.013));

float sdPolyBase(vec2 p){
  float d=dot(p-VERT[0],p-VERT[0]);
  float s=1.0;
  vec2 vj=VERT[NP-1];
  for(int i=0;i<NP;i++){
    vec2 vi=VERT[i];
    vec2 e=vj-vi, w=p-vi;
    vec2 b=w-e*clamp(dot(w,e)/dot(e,e),0.0,1.0);
    d=min(d,dot(b,b));
    bvec3 c=bvec3(p.y>=vi.y, p.y<vj.y, e.x*w.y>e.y*w.x);
    if(all(c)||all(not(c))) s=-s;
    vj=vi;
  }
  return s*sqrt(d);
}
void main(){
  vec2 uv=gl_FragCoord.xy/iSdfRes;
  vec2 wp=(uv*2.0-1.0)*iSdfHalf;
  // центр по кончикам 12 лучей у исходного полигона = (0.0053, 0.0753)
  o=vec4(sdPolyBase(wp+vec2(0.0053,0.0753)),0.0,0.0,1.0);
}`;

// Проход 2: raymarch. Промах луча → alpha 0 (прозрачный фон, canvas поверх страницы).
const FRAG_SRC = `#version 300 es
precision highp float;
out vec4 fragColor;
uniform vec2  iRes;
uniform float iScale[12];
uniform vec2  iCam;
uniform float iZoom;
uniform sampler2D iSdf;
uniform vec2  iSdfHalf;

uniform float iHf;
uniform float iHZ;
uniform float iN;
uniform float iBevel;
uniform float iCut;
uniform vec3  iCream;
uniform vec3  iTerra;
uniform float iSpecAmt;
uniform float iAmb;
uniform float iSat;
uniform float iAA;

#define PI 3.14159265359
#define TAU 6.28318530718

const float ANG[12] = float[12](
  0.2619,0.7678,1.0647,1.6580,2.1468,2.5309,
  3.1416,3.7003,4.2236,4.8692,5.4455,6.1435);

float angDist(float a,float b){ float d=abs(a-b); return min(d,TAU-d); }

float scaleAt(float ang){
  float num=0.0,den=0.0;
  for(int i=0;i<12;i++){
    float dd=angDist(ang,ANG[i]);
    float w=pow(max(0.0,cos(min(dd*1.6,PI*0.5))),6.0)+0.0005;
    num+=w*iScale[i]; den+=w;
  }
  return num/den;
}

float sdPoly(vec2 p){
  float sc=scaleAt(atan(p.y,p.x));
  vec2 q=p/sc;
  vec2 uv=q/(2.0*iSdfHalf)+0.5;
  float d0=texture(iSdf, uv).r;
  return d0*sc;
}

float sdSquircle(vec2 p, float hf, float n){
  p=abs(p)/hf;
  float k=pow(pow(p.x,n)+pow(p.y,n),1.0/n);
  return (k-1.0)*hf;
}
float sdIcon(vec3 p, float hf, float hz, float bevel){
  float dxy=sdSquircle(p.xy, hf, iN);
  vec2 w=vec2(dxy, abs(p.z)-hz);
  return min(max(w.x,w.y),0.0)+length(max(w,0.0))-bevel;
}

float mapInner(vec3 pos){
  float box=sdIcon(pos, iHf, iHZ, iBevel);
  float top=iHZ, bot=iHZ-iCut;
  if(pos.z < bot-0.005) return box;
  float d2=sdPoly(pos.xy);
  float cz=(top+iHZ+0.05)*0.5, hzCut=(iHZ+0.05-bot)*0.5;
  vec2 w=vec2(d2, abs(pos.z-cz)-hzCut);
  float prism=min(max(w.x,w.y),0.0)+length(max(w,0.0));
  return max(box, -prism);
}
float map(vec3 pos){ return mapInner(pos/iZoom)*iZoom; }
vec3 calcNormal(vec3 p){
  const vec2 k=vec2(1.0,-1.0);
  const float e=0.0016;
  return normalize(
    k.xyy*map(p+k.xyy*e)+k.yyx*map(p+k.yyx*e)+
    k.yxy*map(p+k.yxy*e)+k.xxx*map(p+k.xxx*e));
}

// rgb цвета попадания + a=1; промах → vec4(0)
vec4 shade(vec2 px){
  vec2 uv=(px-0.5*iRes)/iRes.y;
  float yaw=iCam.x, pitch=iCam.y;
  float cp=cos(pitch),sp=sin(pitch),cy=cos(yaw),sy=sin(yaw);
  float R=6.0;
  vec3 ro=vec3(R*cp*sy, R*sp, R*cp*cy);
  vec3 fw=normalize(-ro);
  vec3 rt=normalize(cross(fw,vec3(0,1,0)));
  vec3 up=cross(rt,fw);
  vec3 rd=normalize(uv.x*rt+uv.y*up+1.6*fw);

  float Rb=2.6*iZoom;
  float t=0.0; bool hit=false;
  float b=dot(ro,rd);
  float cc=dot(ro,ro)-Rb*Rb;
  float disc=b*b-cc;
  if(disc>=0.0){
    t=-b-sqrt(disc); if(t<0.0) t=0.0;
    for(int i=0;i<110;i++){
      vec3 pos=ro+rd*t;
      float d=map(pos);
      if(d<0.0006){ hit=true; break; }
      if(t>8.0) break;
      t+=d*0.8;
    }
  }
  if(!hit) return vec4(0.0);

  vec3 pos=ro+rd*t;
  vec3 n=calcNormal(pos);
  vec3 Lk=normalize(vec3(0.45,0.7,0.7));
  vec3 Lf=normalize(vec3(-0.5,0.2,0.5));
  float difK=clamp(dot(n,Lk),0.0,1.0);
  float difF=clamp(dot(n,Lf),0.0,1.0);
  float spec=pow(clamp(dot(reflect(-Lk,n),-rd),0.0,1.0),48.0);
  float pz=pos.z/iZoom;
  float inset = smoothstep(iHZ-0.005, iHZ-iCut*0.6, pz);
  vec3 albedo=mix(iTerra, iCream, inset);
  float ao = mix(0.80, 1.0, smoothstep(iHZ-iCut, iHZ-0.005, pz));
  float sheen=pow(clamp(0.5+0.5*n.y,0.0,1.0),3.0);

  vec3 c = albedo*iAmb;
  c += albedo*difK*0.70;
  c += albedo*difF*0.20;
  c *= ao;
  c += albedo*sheen*0.10;
  c += spec*vec3(1.0)*iSpecAmt*(1.0-inset);
  float luma=dot(c,vec3(0.2126,0.7152,0.0722));
  c=mix(vec3(luma),c,iSat);
  return vec4(c,1.0);
}

void main(){
  int n=int(iAA+0.5);
  vec4 acc=vec4(0.0);
  for(int j=0;j<3;j++){ if(j>=n) break;
    for(int i=0;i<3;i++){ if(i>=n) break;
      vec2 off=(vec2(float(i),float(j))+0.5)/float(n)-0.5;
      acc+=shade(gl_FragCoord.xy+off);
    }
  }
  float a=acc.a/float(n*n);
  vec3 col=acc.rgb/max(acc.a,1e-4);      // средний цвет по попавшим сэмплам
  col=pow(clamp(col,0.0,1.0),vec3(0.4545));
  fragColor=vec4(col,a);                  // straight alpha (premultipliedAlpha:false)
}`;

// Экспорт настроек из claude-burst-opt.html — «уголок», режим idle
const P = {
  hf: 1.07, hz: 0.02, n: 4.5, bevel: 0, cut: 0.075,
  cream: "#f6f4ed", terra: "#c65138", spec: 0, amb: 0.4, sat: 1.21, aa: 2,
  // zoom подобран так, чтобы объект заполнял маленький канвас в тулбаре
  // (экспортный 0.43 был под фуллскрин)
  zoom: 1.0, dragYaw: -0.2035, dragPitch: -0.0995,
};

const ANG12 = [0.2619, 0.7678, 1.0647, 1.6580, 2.1468, 2.5309, 3.1416, 3.7003, 4.2236, 4.8692, 5.4455, 6.1435];
const LEN_SVG = [0.922, 0.947, 0.922, 0.954, 0.960, 0.918, 0.953, 0.949, 1.000, 0.871, 0.901, 0.891];
const VID_ANG = [0.3665, 0.8552, 1.1345, 1.6581, 2.0769, 2.4609, 2.9845, 3.6128, 4.1539, 4.8695, 5.5152, 6.2657];
const RAY_LEN = [
  [0.859, 0.847, 0.721, 0.653, 0.703, 0.741, 0.856, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.859, 0.896, 0.756, 0.660, 0.679, 0.701, 0.809, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.859, 0.915, 0.841, 0.700, 0.655, 0.635, 0.717, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.859, 0.915, 0.841, 0.700, 0.655, 0.635, 0.717, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.859, 0.915, 0.887, 0.733, 0.661, 0.611, 0.675, 0.837, 0.871, 0.692, 0.772, 0.804],
  [0.859, 0.915, 0.907, 0.813, 0.703, 0.589, 0.603, 0.739, 0.871, 0.601, 0.772, 0.804],
  [0.859, 0.915, 0.907, 0.813, 0.703, 0.589, 0.603, 0.739, 0.871, 0.601, 0.772, 0.804],
  [0.859, 0.915, 0.907, 0.857, 0.736, 0.595, 0.577, 0.692, 0.833, 0.557, 0.772, 0.804],
  [0.859, 0.915, 0.907, 0.948, 0.819, 0.635, 0.555, 0.615, 0.729, 0.485, 0.751, 0.804],
  [0.859, 0.915, 0.907, 0.948, 0.819, 0.635, 0.555, 0.615, 0.729, 0.485, 0.751, 0.804],
  [0.859, 0.915, 0.907, 0.956, 0.864, 0.665, 0.561, 0.587, 0.680, 0.459, 0.707, 0.804],
  [0.859, 0.915, 0.907, 0.956, 0.955, 0.741, 0.603, 0.563, 0.599, 0.436, 0.631, 0.772],
  [0.859, 0.915, 0.907, 0.956, 0.955, 0.741, 0.603, 0.563, 0.599, 0.436, 0.631, 0.772],
  [0.852, 0.915, 0.907, 0.956, 0.955, 0.784, 0.636, 0.569, 0.569, 0.443, 0.603, 0.724],
  [0.764, 0.915, 0.907, 0.956, 0.955, 0.869, 0.717, 0.615, 0.544, 0.485, 0.580, 0.647],
  [0.764, 0.915, 0.907, 0.956, 0.955, 0.869, 0.717, 0.615, 0.544, 0.485, 0.580, 0.647],
  [0.724, 0.915, 0.907, 0.956, 0.955, 0.901, 0.761, 0.649, 0.551, 0.519, 0.585, 0.619],
  [0.655, 0.847, 0.907, 0.956, 0.955, 0.901, 0.855, 0.739, 0.599, 0.601, 0.631, 0.595],
  [0.655, 0.847, 0.907, 0.956, 0.955, 0.901, 0.855, 0.739, 0.599, 0.601, 0.631, 0.595],
  [0.631, 0.799, 0.907, 0.948, 0.955, 0.901, 0.896, 0.788, 0.636, 0.645, 0.664, 0.601],
  [0.609, 0.719, 0.841, 0.948, 0.955, 0.901, 0.901, 0.857, 0.729, 0.736, 0.751, 0.647],
  [0.609, 0.719, 0.841, 0.948, 0.955, 0.901, 0.901, 0.857, 0.729, 0.736, 0.751, 0.647],
  [0.615, 0.691, 0.796, 0.904, 0.955, 0.901, 0.901, 0.857, 0.780, 0.736, 0.772, 0.683],
  [0.655, 0.665, 0.721, 0.813, 0.953, 0.901, 0.901, 0.857, 0.871, 0.736, 0.772, 0.772],
  [0.655, 0.665, 0.721, 0.813, 0.953, 0.901, 0.901, 0.857, 0.871, 0.736, 0.772, 0.772],
  [0.687, 0.671, 0.695, 0.771, 0.911, 0.901, 0.901, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.764, 0.719, 0.671, 0.701, 0.819, 0.869, 0.901, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.764, 0.719, 0.671, 0.701, 0.819, 0.869, 0.901, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.808, 0.755, 0.677, 0.676, 0.776, 0.827, 0.901, 0.857, 0.871, 0.736, 0.772, 0.804],
  [0.859, 0.847, 0.721, 0.653, 0.703, 0.741, 0.855, 0.857, 0.871, 0.736, 0.772, 0.804],
];
// схлопываем подряд идущие дубли кадров (исходник 30fps с дублями каждого 3-го)
const RAY_U = RAY_LEN.filter((r, i) => i === 0 || r.some((v, k) => v !== RAY_LEN[i - 1]![k]));
const NF = RAY_U.length;
const TAU = Math.PI * 2;

function adist(a: number, b: number): number {
  const d = Math.abs(a - b);
  return Math.min(d, TAU - d);
}
const MAP = ANG12.map((a) => {
  let best = 0, bd = 9;
  VID_ANG.forEach((va, j) => {
    const d = adist(a, va);
    if (d < bd) { bd = d; best = j; }
  });
  return best;
});

function smoothstep(a: number, b: number, x: number): number {
  x = Math.max(0, Math.min(1, (x - a) / (b - a)));
  return x * x * (3 - 2 * x);
}

// idle: редкая медленная волна пульсации, между волнами — ровная звезда
const IDLE = { GAP: 16.0, BURST: 6.0, FADE: 1.6, SPEED: 0.28 };
function idleAmp(t: number): number {
  const ph = ((t % IDLE.GAP) + IDLE.GAP) % IDLE.GAP;
  if (ph > IDLE.BURST) return 0;
  return smoothstep(0.0, IDLE.FADE, ph) * (1.0 - smoothstep(IDLE.BURST - IDLE.FADE, IDLE.BURST, ph));
}
// направление волны чередуется от окна к окну; фазовый скачок невидим (вне окна amp=0)
function wavePhase(t: number): number {
  const ph = ((t % IDLE.GAP) + IDLE.GAP) % IDLE.GAP;
  const dir = Math.floor(t / IDLE.GAP) % 2 === 0 ? 1 : -1;
  return ph * IDLE.SPEED * dir;
}

// лёгкое «дыхание» ракурса
function tiltYaw(t: number): number { return 0.10 * Math.sin(t * 0.23); }
function tiltPitch(t: number): number { return 0.06 * Math.sin(t * 0.17 + 1.3); }

function hex2rgb(h: string): [number, number, number] {
  return [
    parseInt(h.slice(1, 3), 16) / 255,
    parseInt(h.slice(3, 5), 16) / 255,
    parseInt(h.slice(5, 7), 16) / 255,
  ];
}

// Заменяет текст #brand в тулбаре на анимированную звезду.
// Если WebGL2/расширений нет — текст остаётся как был.
export function initBurst(): void {
  const brand = document.getElementById("brand");
  if (!brand) return;
  const cv = document.createElement("canvas");
  cv.id = "burst";
  cv.title = "Session Explorer";
  const gl = cv.getContext("webgl2", { antialias: true, alpha: true, premultipliedAlpha: false });
  if (!gl) return;
  if (!gl.getExtension("EXT_color_buffer_float")) return;
  const extLF = gl.getExtension("OES_texture_float_linear");
  brand.replaceChildren(cv);

  function compile(type: number, src: string): WebGLShader {
    const sh = gl!.createShader(type)!;
    gl!.shaderSource(sh, src.trim());
    gl!.compileShader(sh);
    if (!gl!.getShaderParameter(sh, gl!.COMPILE_STATUS)) throw new Error(gl!.getShaderInfoLog(sh) ?? "shader");
    return sh;
  }
  function link(vs: WebGLShader, fs: WebGLShader): WebGLProgram {
    const p = gl!.createProgram()!;
    gl!.attachShader(p, vs);
    gl!.attachShader(p, fs);
    gl!.linkProgram(p);
    if (!gl!.getProgramParameter(p, gl!.LINK_STATUS)) throw new Error(gl!.getProgramInfoLog(p) ?? "link");
    return p;
  }

  let progBake: WebGLProgram, progMain: WebGLProgram;
  try {
    const vs = compile(gl.VERTEX_SHADER, VERT_SRC);
    progBake = link(vs, compile(gl.FRAGMENT_SHADER, BAKE_SRC));
    progMain = link(vs, compile(gl.FRAGMENT_SHADER, FRAG_SRC));
  } catch {
    brand.textContent = "Session Explorer";
    return;
  }

  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  function bindAttr(prog: WebGLProgram): void {
    const l = gl!.getAttribLocation(prog, "p");
    gl!.enableVertexAttribArray(l);
    gl!.vertexAttribPointer(l, 2, gl!.FLOAT, false, 0, 0);
  }

  // предрасчёт SDF-текстуры (один раз)
  const SDF_RES = 1024;
  const SDF_HALF = 1.2;
  const sdfTex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, sdfTex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16F, SDF_RES, SDF_RES, 0, gl.RED, gl.HALF_FLOAT, null);
  const filt = extLF ? gl.LINEAR : gl.NEAREST;
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filt);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filt);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  const fbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, sdfTex, 0);
  gl.viewport(0, 0, SDF_RES, SDF_RES);
  gl.useProgram(progBake);
  bindAttr(progBake);
  gl.uniform2f(gl.getUniformLocation(progBake, "iSdfRes"), SDF_RES, SDF_RES);
  gl.uniform2f(gl.getUniformLocation(progBake, "iSdfHalf"), SDF_HALF, SDF_HALF);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);

  // основной проход
  gl.useProgram(progMain);
  bindAttr(progMain);
  const L = (n: string) => gl.getUniformLocation(progMain, n);
  const uRes = L("iRes");
  const uScale = L("iScale[0]");
  const uCam = L("iCam");
  const uZoom = L("iZoom");
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, sdfTex);
  gl.uniform1i(L("iSdf"), 0);
  gl.uniform2f(L("iSdfHalf"), SDF_HALF, SDF_HALF);
  gl.uniform1f(L("iHf"), P.hf);
  gl.uniform1f(L("iHZ"), P.hz);
  gl.uniform1f(L("iN"), P.n);
  gl.uniform1f(L("iBevel"), P.bevel);
  gl.uniform1f(L("iCut"), P.cut);
  gl.uniform3fv(L("iCream"), hex2rgb(P.cream));
  gl.uniform3fv(L("iTerra"), hex2rgb(P.terra));
  gl.uniform1f(L("iSpecAmt"), P.spec);
  gl.uniform1f(L("iAmb"), P.amb);
  gl.uniform1f(L("iSat"), P.sat);
  gl.uniform1f(L("iAA"), P.aa);

  // базовый ракурс + ручная орбита поверх
  const baseYaw = -0.42, basePitch = 0.34;
  let dragYaw = P.dragYaw, dragPitch = P.dragPitch;
  let drag = false, lx = 0, ly = 0;
  cv.addEventListener("pointerdown", (e) => {
    drag = true; lx = e.clientX; ly = e.clientY;
    cv.setPointerCapture(e.pointerId);
  });
  cv.addEventListener("pointerup", () => { drag = false; });
  cv.addEventListener("pointermove", (e) => {
    if (!drag) return;
    dragYaw += (e.clientX - lx) * 0.008;
    dragPitch += (e.clientY - ly) * 0.008;
    lx = e.clientX; ly = e.clientY;
  });

  function resize(): void {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.floor(cv.clientWidth * dpr));
    const h = Math.max(1, Math.floor(cv.clientHeight * dpr));
    if (cv.width !== w || cv.height !== h) {
      cv.width = w; cv.height = h;
      gl!.viewport(0, 0, w, h);
    }
  }

  const scBuf = new Float32Array(12);
  function setScale(tm: number, amp: number): void {
    if (amp <= 0.0001) {
      scBuf.fill(1.0);
      gl!.uniform1fv(uScale, scBuf);
      return;
    }
    const ph = ((tm % 1.0) + 1.0) % 1.0, f = ph * NF;
    const i0 = Math.floor(f) % NF, i1 = (i0 + 1) % NF, fr = f - Math.floor(f);
    const a = RAY_U[i0]!, b = RAY_U[i1]!;
    for (let k = 0; k < 12; k++) {
      const vj = MAP[k]!;
      const v = a[vj]! + (b[vj]! - a[vj]!) * fr;
      const target = v / LEN_SVG[k]!;
      scBuf[k] = 1.0 + (target - 1.0) * amp;
    }
    gl!.uniform1fv(uScale, scBuf);
  }

  const t0 = performance.now();
  function tick(now: number): void {
    resize();
    const tm = (now - t0) / 1000;
    const yaw = baseYaw + tiltYaw(tm) + dragYaw;
    let pitch = basePitch + tiltPitch(tm) + dragPitch;
    pitch = Math.max(-1.3, Math.min(1.3, pitch));
    gl!.uniform2f(uRes, cv.width, cv.height);
    setScale(wavePhase(tm), idleAmp(tm));
    gl!.uniform2f(uCam, yaw, pitch);
    gl!.uniform1f(uZoom, P.zoom);
    gl!.clearColor(0, 0, 0, 0);
    gl!.clear(gl!.COLOR_BUFFER_BIT);
    gl!.drawArrays(gl!.TRIANGLES, 0, 3);
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
}
