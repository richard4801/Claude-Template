const fs=require('fs'); const src=fs.readFileSync(process.argv[2],'utf8').split('\n');
const pick=(a,b)=>src.slice(a-1,b).join('\n');
const code = `const localStorage={getItem(){return null},setItem(){}};` + pick(4,27) + '\n' + pick(40,77) + '\n' + pick(226,227) + `
const out={pricing:[],prompts:[]};
for(const engine of ['h3','viggle']) for(const use of ['first','full']) for(const lip of [false,true]) for(const takes of [1,2,4]) for(let steps=4;steps<=30;steps++){
  Object.assign(S,{engine,use,lip,takes,steps});
  out.pricing.push({engine,use,lip,takes,steps,len:LENS(),estMin:estMin(),estCost:estCost(),totalCost:totalCost(),time:fmtMin(estMin()*S.takes),cost:money(totalCost()),genLabel:genLabel(),stepsDelta:stepsDelta()});
}
const combos=[{},{outfit:1,scene:'Café window',shot:'Close',lens:85,aperture:'f/1.4',light:'Ring light',grade:'Warm film',direction:'laughing, holding an iced coffee',lockSeed:false},
 {sceneCustom:'  sunlit rooftop bar, string lights ',lens:16,never:['tattoos','rings','necklaces']},{lens:24,direction:'   ',never:[]},
 {engine:'viggle',bg:'photo',motion:'busy',keepAudio:false,takes:3,use:'full'},{steps:17,bg:'photo',motion:'still'}];
const base=JSON.parse(JSON.stringify(S));
for(const c of combos){ Object.assign(S,JSON.parse(JSON.stringify(base)),{engine:'h3',use:'first',takes:1,steps:10,lip:false},c); out.prompts.push({input:c,shoot:shootPrompt(),video:videoPrompt()}); }
console.log(JSON.stringify(out,null,1));`;
eval(code);
