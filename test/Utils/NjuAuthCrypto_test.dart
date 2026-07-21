import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_test/flutter_test.dart';
import 'package:wheretosleepinnju/Utils/NjuAuthCrypto.dart';

void main() {
  test('encryptNjuPassword produces a non-empty base64 string', () {
    final result = encryptNjuPassword('my-password', '1234567890abcdef');
    expect(result, isNotEmpty);
    // base64 alphabet only
    expect(RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(result), isTrue);
  });

  test('same password/salt always produces the same ciphertext (deterministic)', () {
    final a = encryptNjuPassword('abc123', 'saltsaltsaltsalt');
    final b = encryptNjuPassword('abc123', 'saltsaltsaltsalt');
    expect(a, equals(b));
  });

  test('different passwords produce different ciphertext', () {
    final a = encryptNjuPassword('abc123', 'saltsaltsaltsalt');
    final b = encryptNjuPassword('abc124', 'saltsaltsaltsalt');
    expect(a, isNot(equals(b)));
  });

  test('round-trips back to "a"*64 + password with the same key/iv/padding', () {
    const salt = 'saltsaltsaltsalt'; // 16 字节，AES-128 key 长度
    const password = 'hello-world-123';

    final cipherBase64 = encryptNjuPassword(password, salt);

    final key = encrypt.Key.fromUtf8(salt);
    final iv = encrypt.IV.fromUtf8('a' * 16);
    final decrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
    );
    final decrypted = decrypter.decrypt64(cipherBase64, iv: iv);

    expect(decrypted, equals(('a' * 64) + password));
  });
}
