-- @expect error
-- @line any
-- @contains "upvalues"
-- @hint "Lua 5.4 permits at most 255 upvalues per closure"
-- @code E_LUA_TOO_MANY_UPVALUES
-- Two enclosing scopes each hold <200 locals so the 200-locals-per-function
-- limit does not fire first. The innermost function captures 256 of them,
-- which trips the 255-upvalues-per-closure limit.
local function outer_a()
  local a1=1 local a2=1 local a3=1 local a4=1 local a5=1 local a6=1 local a7=1 local a8=1
  local a9=1 local a10=1 local a11=1 local a12=1 local a13=1 local a14=1 local a15=1 local a16=1
  local a17=1 local a18=1 local a19=1 local a20=1 local a21=1 local a22=1 local a23=1 local a24=1
  local a25=1 local a26=1 local a27=1 local a28=1 local a29=1 local a30=1 local a31=1 local a32=1
  local a33=1 local a34=1 local a35=1 local a36=1 local a37=1 local a38=1 local a39=1 local a40=1
  local a41=1 local a42=1 local a43=1 local a44=1 local a45=1 local a46=1 local a47=1 local a48=1
  local a49=1 local a50=1 local a51=1 local a52=1 local a53=1 local a54=1 local a55=1 local a56=1
  local a57=1 local a58=1 local a59=1 local a60=1 local a61=1 local a62=1 local a63=1 local a64=1
  local a65=1 local a66=1 local a67=1 local a68=1 local a69=1 local a70=1 local a71=1 local a72=1
  local a73=1 local a74=1 local a75=1 local a76=1 local a77=1 local a78=1 local a79=1 local a80=1
  local a81=1 local a82=1 local a83=1 local a84=1 local a85=1 local a86=1 local a87=1 local a88=1
  local a89=1 local a90=1 local a91=1 local a92=1 local a93=1 local a94=1 local a95=1 local a96=1
  local a97=1 local a98=1 local a99=1 local a100=1 local a101=1 local a102=1 local a103=1
  local a104=1 local a105=1 local a106=1 local a107=1 local a108=1 local a109=1 local a110=1
  local a111=1 local a112=1 local a113=1 local a114=1 local a115=1 local a116=1 local a117=1
  local a118=1 local a119=1 local a120=1 local a121=1 local a122=1 local a123=1 local a124=1
  local a125=1 local a126=1 local a127=1 local a128=1
  local function outer_b()
    local b1=1 local b2=1 local b3=1 local b4=1 local b5=1 local b6=1 local b7=1 local b8=1
    local b9=1 local b10=1 local b11=1 local b12=1 local b13=1 local b14=1 local b15=1 local b16=1
    local b17=1 local b18=1 local b19=1 local b20=1 local b21=1 local b22=1 local b23=1 local b24=1
    local b25=1 local b26=1 local b27=1 local b28=1 local b29=1 local b30=1 local b31=1 local b32=1
    local b33=1 local b34=1 local b35=1 local b36=1 local b37=1 local b38=1 local b39=1 local b40=1
    local b41=1 local b42=1 local b43=1 local b44=1 local b45=1 local b46=1 local b47=1 local b48=1
    local b49=1 local b50=1 local b51=1 local b52=1 local b53=1 local b54=1 local b55=1 local b56=1
    local b57=1 local b58=1 local b59=1 local b60=1 local b61=1 local b62=1 local b63=1 local b64=1
    local b65=1 local b66=1 local b67=1 local b68=1 local b69=1 local b70=1 local b71=1 local b72=1
    local b73=1 local b74=1 local b75=1 local b76=1 local b77=1 local b78=1 local b79=1 local b80=1
    local b81=1 local b82=1 local b83=1 local b84=1 local b85=1 local b86=1 local b87=1 local b88=1
    local b89=1 local b90=1 local b91=1 local b92=1 local b93=1 local b94=1 local b95=1 local b96=1
    local b97=1 local b98=1 local b99=1 local b100=1 local b101=1 local b102=1 local b103=1
    local b104=1 local b105=1 local b106=1 local b107=1 local b108=1 local b109=1 local b110=1
    local b111=1 local b112=1 local b113=1 local b114=1 local b115=1 local b116=1 local b117=1
    local b118=1 local b119=1 local b120=1 local b121=1 local b122=1 local b123=1 local b124=1
    local b125=1 local b126=1 local b127=1 local b128=1
    return function()
      -- Capture all 256 (128 a-locals + 128 b-locals) as upvalues.
      return a1+a2+a3+a4+a5+a6+a7+a8+a9+a10+a11+a12+a13+a14+a15+a16+a17+a18+a19+a20
           +a21+a22+a23+a24+a25+a26+a27+a28+a29+a30+a31+a32+a33+a34+a35+a36+a37+a38
           +a39+a40+a41+a42+a43+a44+a45+a46+a47+a48+a49+a50+a51+a52+a53+a54+a55+a56
           +a57+a58+a59+a60+a61+a62+a63+a64+a65+a66+a67+a68+a69+a70+a71+a72+a73+a74
           +a75+a76+a77+a78+a79+a80+a81+a82+a83+a84+a85+a86+a87+a88+a89+a90+a91+a92
           +a93+a94+a95+a96+a97+a98+a99+a100+a101+a102+a103+a104+a105+a106+a107+a108
           +a109+a110+a111+a112+a113+a114+a115+a116+a117+a118+a119+a120+a121+a122+a123
           +a124+a125+a126+a127+a128
           +b1+b2+b3+b4+b5+b6+b7+b8+b9+b10+b11+b12+b13+b14+b15+b16+b17+b18+b19+b20
           +b21+b22+b23+b24+b25+b26+b27+b28+b29+b30+b31+b32+b33+b34+b35+b36+b37+b38
           +b39+b40+b41+b42+b43+b44+b45+b46+b47+b48+b49+b50+b51+b52+b53+b54+b55+b56
           +b57+b58+b59+b60+b61+b62+b63+b64+b65+b66+b67+b68+b69+b70+b71+b72+b73+b74
           +b75+b76+b77+b78+b79+b80+b81+b82+b83+b84+b85+b86+b87+b88+b89+b90+b91+b92
           +b93+b94+b95+b96+b97+b98+b99+b100+b101+b102+b103+b104+b105+b106+b107+b108
           +b109+b110+b111+b112+b113+b114+b115+b116+b117+b118+b119+b120+b121+b122+b123
           +b124+b125+b126+b127+b128
    end
  end
  return outer_b
end
return outer_a
