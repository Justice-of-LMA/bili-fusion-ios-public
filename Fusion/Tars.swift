import Foundation
/// Bounded tagged Tars fields; only the official Huya playback response is decoded.
enum Tars {
 final class Writer {
  var data=Data()
  @discardableResult func head(_ tag:Int,_ type:Int)->Self{data.append(UInt8(tag<15 ? tag*16+type:240+type));if tag>=15{data.append(UInt8(tag))};return self}
  @discardableResult func number(_ tag:Int,_ n:Int64)->Self{if n==0{return head(tag,12)};let size=n>=(-128)&&n<=127 ? 1:n>=(-32768)&&n<=32767 ? 2:n>=Int64(Int32.min)&&n<=Int64(Int32.max) ? 4:8;head(tag,size==1 ? 0:size==2 ? 1:size==4 ? 2:3);for i in (0..<size).reversed(){data.append(UInt8(truncatingIfNeeded:n >> (i*8)))};return self}
  @discardableResult func string(_ tag:Int,_ value:String)->Self{let b=Data(value.utf8);head(tag,b.count<256 ? 6:7);if b.count<256{data.append(UInt8(b.count))}else{var n=UInt32(b.count).bigEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}};data.append(b);return self}
  @discardableResult func bytes(_ tag:Int,_ value:Data)->Self{head(tag,13);head(0,0);number(0,Int64(value.count));data.append(value);return self}
  @discardableResult func structure(_ tag:Int,_ value:Writer)->Self{head(tag,10);data.append(value.data);head(0,11);return self}
  @discardableResult func map(_ tag:Int,_ value:[String:Data])->Self{head(tag,8);number(0,Int64(value.count));for key in value.keys.sorted(){string(0,key);bytes(1,value[key]!)};return self}
 }
 private final class Reader {
  let b:[UInt8];var at=0
  init(_ d:Data){b=Array(d)}
  func take(_ n:Int)throws->[UInt8]{guard n>=0,n<=b.count-at else{throw FusionError("虎牙校验数据不完整")};defer{at+=n};return Array(b[at..<(at+n)])}
  func byte()throws->Int{Int(try take(1)[0])}
  func unsigned(_ n:Int)throws->UInt64{try take(n).reduce(0){($0<<8)|UInt64($1)}}
  func signed(_ n:Int)throws->Int64{let raw=try unsigned(n);return Int64(bitPattern:n<8 && raw&(UInt64(1) << (n*8-1)) != 0 ? raw | (~UInt64(0) << (n*8)):raw)}
  func head()throws->(Int,Int){let h=try byte();return(h>>4==15 ? try byte():h>>4,h&15)}
  func next(_ depth:Int)throws->Any{let h=try head();return try value(h.1,depth+1)}
  func count(_ depth:Int)throws->Int{guard let n=try next(depth) as? Int64,n>=0,n<=100000,n<=Int64(b.count-at+1) else{throw FusionError("虎牙校验长度无效")};return Int(n)}
  func fields(_ depth:Int)throws->[Int:Any]{guard depth<=16 else{throw FusionError("虎牙校验嵌套过深")};var out=[Int:Any]();while at<b.count{let h=try head();if h.1==11{break};out[h.0]=try value(h.1,depth+1);guard out.count<=256 else{throw FusionError("虎牙校验字段过多")}};return out}
  func value(_ type:Int,_ depth:Int)throws->Any{
   guard depth<=16 else{throw FusionError("虎牙校验嵌套过深")}
   switch type {
   case 0:return try signed(1);case 1:return try signed(2);case 2:return try signed(4);case 3:return try signed(8);case 12:return Int64(0)
   case 4:return Float(bitPattern:UInt32(try unsigned(4)));case 5:return Double(bitPattern:try unsigned(8))
   case 6:return String(bytes:try take(byte()),encoding:.utf8) ?? ""
   case 7:return String(bytes:try take(Int(unsigned(4))),encoding:.utf8) ?? ""
   case 8:let n=try count(depth);var out=[String:Any]();for _ in 0..<n{guard let key=try next(depth) as? String else{throw FusionError("虎牙校验键无效")};out[key]=try next(depth)};return out
   case 9:let n=try count(depth);return try (0..<n).map{_ in try next(depth)}
   case 10:return try fields(depth)
   case 13:guard (try byte()) & 15 == 0 else{throw FusionError("虎牙字节类型无效")};return Data(try take(count(depth)))
   default:throw FusionError("虎牙校验字段类型不支持")
   }
  }
 }
 static func read(_ d:Data)throws->[Int:Any]{guard d.count<=2*1024*1024 else{throw FusionError("虎牙校验数据过大")};return try Reader(d).fields(0)}
 static func request(_ name:String,_ payload:Writer)->Data{
  let body=Writer().map(0,["tReq":Writer().structure(0,payload).data])
  let envelope=Writer().number(1,3).number(2,0).number(3,0).number(4,1).string(5,"liveui").string(6,name).bytes(7,body.data).number(8,15000).map(9,[:]).map(10,[:]).data
  var length=UInt32(envelope.count+4).bigEndian;var out=Data();withUnsafeBytes(of:&length){out.append(contentsOf:$0)};out.append(envelope);return out
 }
 static func response(_ data:Data)throws->[Int:Any]{
  guard data.count>=4,let body=try read(data.dropFirst(4))[7] as? Data,let fields=try read(body)[0] as? [String:Any],let raw=fields["tRsp"] as? Data,let result=try read(raw)[0] as? [Int:Any] else{throw FusionError("虎牙播放校验响应无效")};return result
 }
}

