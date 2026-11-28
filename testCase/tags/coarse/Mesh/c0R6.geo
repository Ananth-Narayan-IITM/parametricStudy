L = 2;
H = 1;
Nx = 125;
Ny = 250;
//+
Point(1) = {0, 0, 0, 1.0};
//+
Point(2) = {L, 0, 0, 1.0};
//+
Point(3) = {0, H, 0, 1.0};
//+
Point(4) = {L, H, 0, 1.0};
//+
Line(1) = {1, 2};
//+
Line(2) = {2, 4};
//+
Line(3) = {4, 3};
//+
Line(4) = {3, 1};
//+
Curve Loop(1) = {4, 1, 2, 3};
//+
Plane Surface(1) = {1};
//+
Transfinite Curve {4, 2} = Nx Using Progression 1;
//+
Transfinite Curve {3, 1} = Ny Using Progression 1;
//+
Transfinite Surface {1};
//+
Recombine Surface {1};
//+
Extrude {0, 0, 1e-2} {
  Surface{1}; Layers{1}; Recombine;
}
//+
Physical Surface("topWall") = {25};
//+
Physical Surface("bottomWall") = {17};
//+
Physical Surface("leftWall") = {13};
//+
Physical Surface("rightWall") = {21};
//+
Physical Surface("frontBack") = {26, 1};
//+
Physical Volume("fluid") = {1};
