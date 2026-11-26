/*{
  "ISFVSN": "2.0",
  "DESCRIPTION": "Original normalized source tint for the ApertureCue expression subset",
  "CREDIT": "ApertureCue contributors; GPL-3.0-or-later",
  "CATEGORIES": ["ApertureCue Original"],
  "INPUTS": [
    {"NAME":"inputImage","TYPE":"image"},
    {"NAME":"tint","TYPE":"color","DEFAULT":[0.9,0.6,0.3,1.0],"MIN":[0.0,0.0,0.0,0.0],"MAX":[1.0,1.0,1.0,1.0]}
  ]
}*/
void main() {
    gl_FragColor = IMG_NORM_PIXEL(inputImage, isf_FragNormCoord) * tint;
}
