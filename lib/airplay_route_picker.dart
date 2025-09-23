import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AirPlayRoutePicker extends StatelessWidget {
  const AirPlayRoutePicker({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      // Na Androidzie nic nie renderujemy (AirPlay tylko na iOS).
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: size + 8,
      height: size + 8,
      child: const UiKitView(
        viewType: 'mtl.airplay.routepicker',
        creationParams: <String, dynamic>{},
        creationParamsCodec: StandardMessageCodec(),
      ),
    );
  }
}
