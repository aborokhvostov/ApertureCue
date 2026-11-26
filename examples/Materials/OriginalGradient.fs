/*{
  "ISFVSN": "2.0",
  "DESCRIPTION": "Original animated gradient for the ApertureCue expression subset",
  "CREDIT": "ApertureCue contributors; GPL-3.0-or-later",
  "CATEGORIES": ["ApertureCue Original"],
  "INPUTS": [{"NAME":"speed","TYPE":"float","DEFAULT":0.5,"MIN":0.0,"MAX":2.0}]
}*/
void main() {
    gl_FragColor = vec4(isf_FragNormCoord.x, isf_FragNormCoord.y, 0.5 + 0.5 * sin(TIME * speed), 1.0);
}
