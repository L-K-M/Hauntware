import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('vault key checks authenticate the key and account identity', () async {
    final key = secureRandomBytes(32);
    final check = await VaultKeyCheck.create(key, username: 'me');

    await expectLater(
      VaultKeyCheck.verify(key, check, username: 'me'),
      completes,
    );
    await expectLater(
      VaultKeyCheck.verify(secureRandomBytes(32), check, username: 'me'),
      throwsA(anything),
    );
    await expectLater(
      VaultKeyCheck.verify(key, check, username: 'someone-else'),
      throwsA(anything),
    );
  });

  test('register and login DTOs carry the vault key check', () {
    const request = RegisterRequest(
      username: 'me',
      authVerifier: 'dmVyaWZpZXI=',
      argonSalt: 'c2FsdA==',
      argonParams: Argon2Params(),
      vaultKeyCheck: 'Y2hlY2s=',
    );
    final registered = RegisterRequest.fromJson(request.toJson());
    expect(registered.vaultKeyCheck, 'Y2hlY2s=');

    final login = LoginResponse.fromJson(
      LoginResponse(
        token: 'token',
        vaultKeyCheck: registered.vaultKeyCheck,
      ).toJson(),
    );
    expect(login.vaultKeyCheck, 'Y2hlY2s=');
  });

  test('prelogin never exposes the offline vault verifier', () {
    const response = PreloginResponse(
      argonSalt: 'c2FsdA==',
      argonParams: Argon2Params(),
    );
    expect(response.toJson().containsKey('vaultKeyCheck'), isFalse);
  });
}
