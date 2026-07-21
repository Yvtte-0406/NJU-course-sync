import 'package:encrypt/encrypt.dart' as encrypt;

/// 复刻南大统一认证登录页对密码字段做的客户端加密。
///
/// 参考实现（MIT 协议，已确认可参考复用）：
/// https://github.com/nju-cli/nju-cli/blob/main/crates/common/src/unified_auth.rs
///
/// 算法：key 用登录页隐藏字段 `pwdEncryptSalt` 的值（AES-128，要求正好 16 字节），
/// IV 固定是 16 个 'a'，明文在密码前面垫 64 个 'a' 做混淆，PKCS7 填充，
/// AES-128-CBC 加密，结果 base64 编码——跟登录页自己的 JS 做的是同一件事，
/// 这里只是在 Dart 里重新算一遍，不需要靠模拟打字触发页面逻辑。
String encryptNjuPassword(String password, String salt) {
  final key = encrypt.Key.fromUtf8(salt);
  final iv = encrypt.IV.fromUtf8('a' * 16);
  final encrypter = encrypt.Encrypter(
    encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
  );
  final plainText = ('a' * 64) + password;
  final encrypted = encrypter.encrypt(plainText, iv: iv);
  return encrypted.base64;
}
