-- @expect error
-- @line any
-- @contains "too many local variables"
-- @hint "Lua 5.4 permits at most 200 active locals per function"
-- @code E_LUA_TOO_MANY_LOCALS
-- 300+ locals in a single scope triggers the 200-local ceiling.
local function too_many()
  local a1=1 local a2=1 local a3=1 local a4=1 local a5=1 local a6=1 local a7=1 local a8=1
  local a9=1 local a10=1 local a11=1 local a12=1 local a13=1 local a14=1 local a15=1
  local a16=1 local a17=1 local a18=1 local a19=1 local a20=1 local a21=1 local a22=1
  local a23=1 local a24=1 local a25=1 local a26=1 local a27=1 local a28=1 local a29=1
  local a30=1 local a31=1 local a32=1 local a33=1 local a34=1 local a35=1 local a36=1
  local a37=1 local a38=1 local a39=1 local a40=1 local a41=1 local a42=1 local a43=1
  local a44=1 local a45=1 local a46=1 local a47=1 local a48=1 local a49=1 local a50=1
  local a51=1 local a52=1 local a53=1 local a54=1 local a55=1 local a56=1 local a57=1
  local a58=1 local a59=1 local a60=1 local a61=1 local a62=1 local a63=1 local a64=1
  local a65=1 local a66=1 local a67=1 local a68=1 local a69=1 local a70=1 local a71=1
  local a72=1 local a73=1 local a74=1 local a75=1 local a76=1 local a77=1 local a78=1
  local a79=1 local a80=1 local a81=1 local a82=1 local a83=1 local a84=1 local a85=1
  local a86=1 local a87=1 local a88=1 local a89=1 local a90=1 local a91=1 local a92=1
  local a93=1 local a94=1 local a95=1 local a96=1 local a97=1 local a98=1 local a99=1
  local a100=1 local a101=1 local a102=1 local a103=1 local a104=1 local a105=1 local a106=1
  local a107=1 local a108=1 local a109=1 local a110=1 local a111=1 local a112=1 local a113=1
  local a114=1 local a115=1 local a116=1 local a117=1 local a118=1 local a119=1 local a120=1
  local a121=1 local a122=1 local a123=1 local a124=1 local a125=1 local a126=1 local a127=1
  local a128=1 local a129=1 local a130=1 local a131=1 local a132=1 local a133=1 local a134=1
  local a135=1 local a136=1 local a137=1 local a138=1 local a139=1 local a140=1 local a141=1
  local a142=1 local a143=1 local a144=1 local a145=1 local a146=1 local a147=1 local a148=1
  local a149=1 local a150=1 local a151=1 local a152=1 local a153=1 local a154=1 local a155=1
  local a156=1 local a157=1 local a158=1 local a159=1 local a160=1 local a161=1 local a162=1
  local a163=1 local a164=1 local a165=1 local a166=1 local a167=1 local a168=1 local a169=1
  local a170=1 local a171=1 local a172=1 local a173=1 local a174=1 local a175=1 local a176=1
  local a177=1 local a178=1 local a179=1 local a180=1 local a181=1 local a182=1 local a183=1
  local a184=1 local a185=1 local a186=1 local a187=1 local a188=1 local a189=1 local a190=1
  local a191=1 local a192=1 local a193=1 local a194=1 local a195=1 local a196=1 local a197=1
  local a198=1 local a199=1 local a200=1 local a201=1 local a202=1 local a203=1 local a204=1
  local a205=1 local a206=1 local a207=1 local a208=1 local a209=1 local a210=1 local a211=1
  local a212=1 local a213=1 local a214=1 local a215=1 local a216=1 local a217=1 local a218=1
  local a219=1 local a220=1 local a221=1 local a222=1 local a223=1 local a224=1 local a225=1
  local a226=1 local a227=1 local a228=1 local a229=1 local a230=1 local a231=1 local a232=1
  local a233=1 local a234=1 local a235=1 local a236=1 local a237=1 local a238=1 local a239=1
  local a240=1 local a241=1 local a242=1 local a243=1 local a244=1 local a245=1 local a246=1
  local a247=1 local a248=1 local a249=1 local a250=1 local a251=1 local a252=1 local a253=1
  local a254=1 local a255=1 local a256=1 local a257=1 local a258=1 local a259=1 local a260=1
  local a261=1 local a262=1 local a263=1 local a264=1 local a265=1 local a266=1 local a267=1
  local a268=1 local a269=1 local a270=1 local a271=1 local a272=1 local a273=1 local a274=1
  local a275=1 local a276=1 local a277=1 local a278=1 local a279=1 local a280=1 local a281=1
  local a282=1 local a283=1 local a284=1 local a285=1 local a286=1 local a287=1 local a288=1
  local a289=1 local a290=1 local a291=1 local a292=1 local a293=1 local a294=1 local a295=1
  local a296=1 local a297=1 local a298=1 local a299=1 local a300=1
  return a1 + a300
end
return too_many
