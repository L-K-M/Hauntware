import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _darwinPdfiumProviderMetadataKey = 'darwin_pdfium_provider';
const _pdfiumFlutterXcframeworkProvider = 'pdfium_flutter_xcframework';
const _pdfiumAssetId = 'package:pdfium_dart/libpdfium';

void main(List<String> args) async {
  await link(args, linkPdfiumAssets);
}

Future<void> linkPdfiumAssets(LinkInput input, LinkOutputBuilder output) async {
  if (!input.config.buildCodeAssets) {
    output.assets.addEncodedAssets(input.assets.encodedAssets);
    return;
  }

  final targetOS = input.config.code.targetOS;
  final pdfiumProvidedByFlutter =
      input.metadata[_darwinPdfiumProviderMetadataKey] ==
      _pdfiumFlutterXcframeworkProvider;
  // Poltergeist: omit the asset on macOS too. Upstream keeps it for
  // `flutter test`, but Flutter runs link hooks only for profile and release
  // builds, so a test run never reaches this filter. In an app build the
  // asset becomes `pdfium.framework`, which on a case-insensitive volume
  // lands on top of the XCFramework's signed `PDFium.framework` and breaks
  // the app's code signature.
  final shouldOmitDarwinPdfiumAsset =
      pdfiumProvidedByFlutter && (targetOS == OS.iOS || targetOS == OS.macOS);

  for (final asset in input.assets.encodedAssets) {
    final isPdfiumAsset =
        asset.isCodeAsset && CodeAsset.fromEncoded(asset).id == _pdfiumAssetId;
    if (shouldOmitDarwinPdfiumAsset && isPdfiumAsset) continue;

    output.assets.addEncodedAsset(asset);
  }
}
