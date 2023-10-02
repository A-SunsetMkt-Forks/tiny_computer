// workflow.dart  --  This file is part of tiny_computer.               
                                                                        
// Copyright (C) 2023 Caten Hu                                          
                                                                        
// Tiny Computer is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published    
// by the Free Software Foundation, either version 3 of the License,    
// or any later version.                               
                                                                         
// Tiny Computer is distributed in the hope that it will be useful,          
// but WITHOUT ANY WARRANTY; without even the implied warranty          
// of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.              
// See the GNU General Public License for more details.                 
                                                                     
// You should have received a copy of the GNU General Public License    
// along with this program.  If not, see http://www.gnu.org/licenses/.

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:intl/intl.dart';

import 'package:http/http.dart' as http;
import 'package:retry/retry.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:xterm/xterm.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:unity_ads_plugin/unity_ads_plugin.dart';

import 'package:clipboard/clipboard.dart';

class Util {

  static Future<void> copyAsset(String src, String dst) async {
    await File(dst).writeAsBytes((await rootBundle.load(src)).buffer.asUint8List());
  }
  static Future<void> copyAsset2(String src, String dst) async {
    ByteData data = await rootBundle.load(src);
    await File(dst).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }
  static void createDirFromString(String dir) {
    Directory.fromRawPath(const Utf8Encoder().convert(dir)).createSync(recursive: true);
  }

  static Future<void> execute(String str) async {
    Pty pty = Pty.start(
      "/system/bin/sh"
    );
    pty.write(const Utf8Encoder().convert("$str\nexit\n"));
    await pty.exitCode;
  }

  static void termWrite(String str) {
    G.termPtys[G.currentContainer]!.pty.write(const Utf8Encoder().convert("$str\n"));
  }

  static dynamic getCurrentProp(String key) {
    return jsonDecode(G.prefs.getStringList("containersInfo")![G.currentContainer])[key];
  }

  //用来设置name, boot, vnc, vncUrl等
  static Future<void> setCurrentProp(String key, dynamic value) async {
    await G.prefs.setStringList("containersInfo",
      G.prefs.getStringList("containersInfo")!..setAll(G.currentContainer,
        [jsonEncode((jsonDecode(
          G.prefs.getStringList("containersInfo")![G.currentContainer]
        ))..update(key, (v) => value))]
      )
    );
  }

  //返回单个G.bonusTable定义的item
  static Map<String, dynamic> getRandomBonus() {
    final random = Random();
    final totalWeight = G.bonusTable.fold(0.0, (sum, item) => sum + item['weight']);
    final randomIndex = random.nextDouble() * totalWeight;
    var cumulativeWeight = 0.0;
    for (final item in G.bonusTable) {
      cumulativeWeight += item['weight'];
      if (randomIndex <= cumulativeWeight) {
        return item;
      }
    }
    return G.bonusTable[0];
  }

  //由getRandomBonus返回的数据
  static Future<void> applyBonus(Map<String, dynamic> bonus) async {
    bool flag = false;
    List<String> ret = G.prefs.getStringList("adsBonus")!.map((e) {
      Map<String, dynamic> item = jsonDecode(e);
      return (item["name"] == bonus["name"])?
        jsonEncode(item..update("amount", (v) {
          flag = true;
          return v + bonus["amount"];
        })):e;
    }).toList();
    if (!flag) {
      ret.add("""{"name": "${bonus["name"]}", "amount": ${bonus["amount"]}}""");
    }
    await G.prefs.setStringList("adsBonus", ret);
  }

  //根据已看广告量判断是否应该继续看广告
  static bool shouldWatchAds(int expectNum) {
    return (G.prefs.getInt("adsWatchedTotal")! < expectNum) && (G.prefs.getInt("vip")! < 1) && (G.prefs.getInt("adsWatchedToday")! < 5);
  }

  //限定字符串在min和max之间, 给文本框的validator
  static String? validateBetween(String? value, int min, int max, Function opr) {
    if (value == null || value.isEmpty) {
      return "请输入数字";
    }
    int? parsedValue = int.tryParse(value);
    if (parsedValue == null) {
      return "请输入有效的数字";
    }
    if (parsedValue < min || parsedValue > max) {
      return "请输入$min到$max之间的数字";
    }
    opr();
    return null;
  }
}

//来自xterms关于操作ctrl, shift, alt键的示例
//这个类应该只能有一个实例G.keyboard
class VirtualKeyboard extends TerminalInputHandler with ChangeNotifier {
  final TerminalInputHandler _inputHandler;

  VirtualKeyboard(this._inputHandler);

  bool _ctrl = false;

  bool get ctrl => _ctrl;

  set ctrl(bool value) {
    if (_ctrl != value) {
      _ctrl = value;
      notifyListeners();
    }
  }

  bool _shift = false;

  bool get shift => _shift;

  set shift(bool value) {
    if (_shift != value) {
      _shift = value;
      notifyListeners();
    }
  }

  bool _alt = false;

  bool get alt => _alt;

  set alt(bool value) {
    if (_alt != value) {
      _alt = value;
      notifyListeners();
    }
  }

  @override
  String? call(TerminalKeyboardEvent event) {
    final ret = _inputHandler.call(event.copyWith(
      ctrl: event.ctrl || _ctrl,
      shift: event.shift || _shift,
      alt: event.alt || _alt,
    ));
    G.maybeCtrlJ = event.key.name == "keyJ";
    print(G.maybeCtrlJ);
    if (!G.prefs.getBool("isStickyKey")!) {
      G.keyboard.ctrl = false;
      G.keyboard.shift = false;
      G.keyboard.alt = false;
    }
    return ret;
  }
}

//一个结合terminal和pty的类
class TermPty {
  late final Terminal terminal;
  late final Pty pty;

  TermPty() {
    terminal = Terminal(inputHandler: G.keyboard, maxLines: G.prefs.getInt("termMaxLines")!);
    pty = Pty.start(
      "/system/bin/sh",
      workingDirectory: G.dataPath,
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .listen(terminal.write);
    pty.exitCode.then((code) {
      terminal.write('the process exited with exit code $code');
      if (code == 0) {
        SystemChannels.platform.invokeMethod("SystemNavigator.pop");
      }
      //TODO: Signal 9 hint, 改成对话框?
      if (code == -9) {
        Navigator.push(G.homePageStateContext, MaterialPageRoute(builder: (context) {
          const TextStyle ts = TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.normal);
          const String helperLink = "https://www.vmos.cn/zhushou.htm";
          return Scaffold(backgroundColor: Colors.deepPurple,
            body: Center(
            child: Scrollbar(child:
              SingleChildScrollView(
                child: Column(children: [
                  const Text(":(\n发生了什么？", textScaleFactor: 2, style: ts, textAlign: TextAlign.center,),
                  const Text("终端异常退出, 返回错误码9\n此错误通常是高版本安卓系统(12+)限制进程造成的, \n可以使用以下工具修复:", style: ts, textAlign: TextAlign.center),
                  const SelectableText(helperLink, style: ts, textAlign: TextAlign.center),
                  const Text("(复制链接到浏览器查看)", style: ts, textAlign: TextAlign.center),
                  OutlinedButton(onPressed: () {
                    FlutterClipboard.copy(helperLink).then(( value ) {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: const Text("已复制"), action: SnackBarAction(label: "跳转", onPressed: () {
                          launchUrl(Uri.parse(helperLink), mode: LaunchMode.externalApplication);
                        },))
                      );
                    });
                  }, child: const Text("复制", style: ts, textAlign: TextAlign.center))
                ]),
              )
            )
          ));
        }));
      }
    });
    terminal.onOutput = (data) {
      if (!G.prefs.getBool("isTerminalWriteEnabled")!) {
        return;
      }
      //由于对回车的处理似乎存在问题，所以拿出来单独处理
      data.split("").forEach((element) {
        if (element == "\n" && !G.maybeCtrlJ) {
          terminal.keyInput(TerminalKey.enter);
          return;
        }
        G.maybeCtrlJ = false;
        pty.write(const Utf8Encoder().convert(element));
      });
    };
    terminal.onResize = (w, h, pw, ph) {
      pty.resize(h, w);
    };
  }

}

// Global variables
class G {
  static late final String dataPath;
  static Pty? audioPty;
  static late WebViewController controller;
  static late BuildContext homePageStateContext;
  static late int currentContainer; //目前运行第几个容器
  static late Map<int, TermPty> termPtys; //为容器<int>存放TermPty数据
  static late AdManager ads; //广告实例
  static late VirtualKeyboard keyboard; //存储ctrl, shift, alt状态
  static bool maybeCtrlJ = false; //为了区分按下的ctrl+J和enter而准备的变量
  static double termFontScale = 1; //终端字体大小，存储为G.prefs的termFontScale


  //看广告可以获得的奖励。
  //weight抽奖权重，singleUse使用一次花费的数量，amount抽中可以获得的数量
  static const List<Map<String, dynamic>> bonusTable = [
    {"name": "开发者的祝福", "subtitle": "支持开发者的证明", "description": "(*'v'*)\n开发者由衷地感谢你!", "weight": 10000, "amount": 1, "singleUse": 0},
    {"name": "记忆晶片", "subtitle": "看上去像平行四边形", "description": "组成记忆空间的基本元素。\n是从哪里掉下来的呢?", "weight": 50, "amount": 1, "singleUse": 0},
    {"name": "Wishes Flower Part", "subtitle": "为1个人献上祝福", "description": "希望之花的花瓣。在想好为谁祝福后, 点击使用", "weight": 500, "amount": 1, "singleUse": 1},
    {"name": "Wishes Flower Part", "subtitle": "为1个人献上祝福", "description": "希望之花的花瓣。在想好为谁祝福后, 点击使用", "weight": 100, "amount": 3, "singleUse": 1},
    {"name": "Wishes Flower", "subtitle": "为3个人献上祝福", "description": "希望之花。在想好为谁祝福后, 点击使用", "weight": 50, "amount": 1, "singleUse": 1},
    {"name": "Bonus Reward", "subtitle": "会有极好的事情发生", "description": "来自记忆空间的传说。\n使用后一天内必有极好的事情...\n就是你想象的那种事情...\n就会发生。\n不过, 大概只是个传说吧。", "weight": 10, "amount": 0.01, "singleUse": 1},
    {"name": "Bonus Reward", "subtitle": "会有极好的事情发生", "description": "来自记忆空间的传说。\n使用后一天内必有极好的事情...\n就是你想象的那种事情...\n就会发生。\n不过, 大概只是个传说吧。", "weight": 1, "amount": 0.1, "singleUse": 1},
    {"name": "Bonus Reward", "subtitle": "会有极好的事情发生", "description": "来自记忆空间的传说。\n使用后一天内必有极好的事情...\n就是你想象的那种事情...\n就会发生。\n不过, 大概只是个传说吧。", "weight": 1, "amount": 1, "singleUse": 1},
  ];

  //所有key
  //int defaultContainer = 0: 默认启动第0个容器
  //int defaultAudioPort = 4718: 默认pulseaudio端口(为了避免和其它软件冲突改成4718了，原默认4713)
  //bool autoLaunchVnc = true: 是否自动启动VNC并跳转
  //String lastDate: 上次启动软件的日期，yyyy-MM-dd
  //int adsWatchedToday: 今日视频广告观看数量
  //int adsWatchedTotal: 视频广告观看数量
  //bool isBannerAdsClosed = false
  //bool bannerAdsCanBeClosed = false 看一次视频广告永久开启，历史遗留
  //bool isTerminalWriteEnabled = false
  //bool terminalWriteCanBeEnabled = false 看一次视频广告永久开启，历史遗留
  //bool isTerminalCommandsEnabled = false 
  //int termMaxLines = 4095 终端最大行数
  //double termFontScale = 1 终端字体大小
  //int vip = 0 用户等级，vip免广告，你要改吗？(ToT)
  //bool isStickyKey = true 终端ctrl, shift, alt键是否粘滞
  //? int bootstrapVersion: 启动包版本
  //String[] containersInfo: 所有容器信息(json)
  //{name, boot:"\$DATA_DIR/bin/proot ...", vnc:"startnovnc", vncUrl:"...", commands:[{name:"更新和升级", command:"apt update -y && apt upgrade -y"}, ...]}
  //String[] adsBonus: 观看广告获取的奖励(json)
  //{name: "xxx", amount: xxx}
  static late SharedPreferences prefs;

}

class AdManager {
  
  static Map<String, bool> placements = {
    interstitialVideoAdPlacementId: false,
    rewardedVideoAdPlacementId: false,
  };

  static void loadAds() {
    for (var placementId in placements.keys) {
      loadAd(placementId);
    }
  }

  static void loadAd(String placementId) {
    UnityAds.load(
      placementId: placementId,
      onComplete: (placementId) {
        debugPrint('Load Complete $placementId');
        placements[placementId] = true;
      },
      onFailed: (placementId, error, message) => debugPrint('Load Failed $placementId: $error $message'),
    );
  }

  static void showAd(String placementId, Function completeExtra, Function full) {

    if (G.prefs.getInt("adsWatchedToday")!>=5) {
      full();
      return;
    }

    placements[placementId] = false;
    UnityAds.showVideoAd(
      placementId: placementId,
      onComplete: (placementId) async {
        debugPrint('Video Ad $placementId completed');
        loadAd(placementId);
        await G.prefs.setInt("adsWatchedTotal", G.prefs.getInt("adsWatchedTotal")!+1);
        await G.prefs.setInt("adsWatchedToday", G.prefs.getInt("adsWatchedToday")!+1);
        completeExtra();
      },
      onFailed: (placementId, error, message) {
        debugPrint('Video Ad $placementId failed: $error $message');
        loadAd(placementId);
      },
      onStart: (placementId) => debugPrint('Video Ad $placementId started'),
      onClick: (placementId) => debugPrint('Video Ad $placementId click'),
      onSkipped: (placementId) {
        debugPrint('Video Ad $placementId skipped');
        loadAd(placementId);
      },
    );
  }

  static String get gameId {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return '5403132';
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return '5403133';
    }
    return '';
  }

  static String bannerAdPlacementId = 'Banner_Android';

  static String interstitialVideoAdPlacementId = 'Interstitial_Android';

  static String rewardedVideoAdPlacementId = 'Rewarded_Android';
}

class Workflow {

  static Future<void> grantPermissions() async {
    Permission.storage.request();
    Permission.manageExternalStorage.request();
  }

  static Future<void> setupBootstrap() async {
    //用来共享数据文件的文件夹
    Util.createDirFromString("${G.dataPath}/share");
    //挂载到/dev/shm的文件夹
    Util.createDirFromString("${G.dataPath}/tmp");
    //给proot的tmp文件夹，虽然我不知道为什么proot要这个
    Util.createDirFromString("${G.dataPath}/proot_tmp");
    //解压后得到bin文件夹和libexec文件夹
    //bin存放了proot, pulseaudio, tar等
    //libexec存放了proot loader
    await Util.copyAsset(
    "assets/assets.zip",
    "${G.dataPath}/assets.zip",
    );
    //dddd
    await Util.copyAsset(
    "assets/busybox",
    "${G.dataPath}/busybox",
    );
    await Util.execute(
"""
export DATA_DIR=${G.dataPath}
cd \$DATA_DIR
chmod +x busybox
\$DATA_DIR/busybox unzip assets.zip
chmod -R +x bin/*
chmod -R +x libexec/proot/*
chmod 1777 tmp
ln -s \$DATA_DIR/busybox \$DATA_DIR/bin/xz
\$DATA_DIR/busybox rm -rf assets.zip
""");
  }

  //初次启动要做的事情
  static Future<void> initForFirstTime() async {
    //首先设置bootstrap
    await setupBootstrap();
    //存放容器的文件夹0和存放硬链接的文件夹.l2s
    Util.createDirFromString("${G.dataPath}/containers/0/.l2s");
    //这个是容器rootfs，被split命令分成了xa*
    //首次启动，就用这个，别让用户另选了
    //TODO: 这个字符串列表太丑陋了
    for (String name in ["xaa", "xab", "xac", "xad", "xae", "xaf", "xag", "xah", "xai"]) {
    //for (String name in ["xaa", "xab", "xac", "xad", "xae", "xaf", "xag", "xah", "xai", "xaj", "xak", "xal", "xam", "xan", "xao", "xap", "xaq"]) {
      await Util.copyAsset("assets/$name", "${G.dataPath}/$name");
    }
    //-J
    await Util.execute(
"""
export DATA_DIR=${G.dataPath}
export CONTAINER_DIR=\$DATA_DIR/containers/0
cd \$DATA_DIR
export PATH=\$DATA_DIR/bin:\$PATH
export PROOT_TMP_DIR=\$DATA_DIR/proot_tmp
export PROOT_LOADER=\$DATA_DIR/libexec/proot/loader
export PROOT_LOADER_32=\$DATA_DIR/libexec/proot/loader32
export PROOT_L2S_DIR=\$CONTAINER_DIR/.l2s
\$DATA_DIR/bin/proot --link2symlink sh -c "cat xa* | \$DATA_DIR/bin/tar x -J --delay-directory-restore --preserve-permissions -v -C containers/0"
#Script from proot-distro
chmod u+rw "\$CONTAINER_DIR/etc/passwd" "\$CONTAINER_DIR/etc/shadow" "\$CONTAINER_DIR/etc/group" "\$CONTAINER_DIR/etc/gshadow"
echo "aid_\$(id -un):x:\$(id -u):\$(id -g):Termux:/:/sbin/nologin" >> "\$CONTAINER_DIR/etc/passwd"
echo "aid_\$(id -un):*:18446:0:99999:7:::" >> "\$CONTAINER_DIR/etc/shadow"
id -Gn | tr ' ' '\\n' > tmp1
id -G | tr ' ' '\\n' > tmp2
\$DATA_DIR/busybox paste tmp1 tmp2 > tmp3
local group_name group_id
cat tmp3 | while read -r group_name group_id; do
	echo "aid_\${group_name}:x:\${group_id}:root,aid_\$(id -un)" >> "\$CONTAINER_DIR/etc/group"
	if [ -f "\$CONTAINER_DIR/etc/gshadow" ]; then
		echo "aid_\${group_name}:*::root,aid_\$(id -un)" >> "\$CONTAINER_DIR/etc/gshadow"
	fi
done
\$DATA_DIR/busybox rm -rf xa* tmp1 tmp2 tmp3
""");
    //一些数据初始化
    //$DATA_DIR是数据文件夹, $CONTAINER_DIR是容器根目录
    await G.prefs.setStringList("containersInfo", ["""{
"name":"Debian Bookworm",
"boot":"\$DATA_DIR/bin/proot --change-id=1000:1000 --pwd=/home/tiny --rootfs=\$CONTAINER_DIR --mount=/system --mount=/apex --kill-on-exit --mount=/storage:/storage --sysvipc -L --link2symlink --mount=/proc:/proc --mount=/dev:/dev --mount=\$CONTAINER_DIR/tmp:/dev/shm --mount=/dev/urandom:/dev/random --mount=/proc/self/fd:/dev/fd --mount=/proc/self/fd/0:/dev/stdin --mount=/proc/self/fd/1:/dev/stdout --mount=/proc/self/fd/2:/dev/stderr --mount=/dev/null:/dev/tty0 --mount=/dev/null:/proc/sys/kernel/cap_last_cap --mount=/storage/self/primary:/media/sd --mount=\$DATA_DIR/share:/home/tiny/公共 --mount=/storage/self/primary/Fonts:/usr/share/fonts/wpsm --mount=/storage/self/primary/AppFiles/Fonts:/usr/share/fonts/yozom --mount=/system/fonts:/usr/share/fonts/androidm --mount=/storage/self/primary/Pictures:/home/tiny/图片 --mount=/storage/self/primary/Music:/home/tiny/音乐 --mount=/storage/self/primary/Movies:/home/tiny/视频 --mount=/storage/self/primary/Download:/home/tiny/下载 --mount=/storage/self/primary/DCIM:/home/tiny/照片 --mount=/storage/self/primary/Documents:/home/tiny/文档 --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/.tmoe-container.stat:/proc/stat --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/.tmoe-container.version:/proc/version --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/bus:/proc/bus --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/buddyinfo:/proc/buddyinfo --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/cgroups:/proc/cgroups --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/consoles:/proc/consoles --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/crypto:/proc/crypto --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/devices:/proc/devices --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/diskstats:/proc/diskstats --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/execdomains:/proc/execdomains --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/fb:/proc/fb --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/filesystems:/proc/filesystems --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/interrupts:/proc/interrupts --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/iomem:/proc/iomem --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/ioports:/proc/ioports --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/kallsyms:/proc/kallsyms --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/keys:/proc/keys --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/key-users:/proc/key-users --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linuxproot_proc/kpageflags:/proc/kpageflags --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/loadavg:/proc/loadavg --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/locks:/proc/locks --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/misc:/proc/misc --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/modules:/proc/modules --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/pagetypeinfo:/proc/pagetypeinfo --mount=/data/data/com.termux/files/home/.local/share/tmoe-linux/containersproot/debian-bookworm_arm64/usr/local/etc/tmoe-linux/proot_proc/partitions:/proc/partitions --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/sched_debug:/proc/sched_debug --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/softirqs:/proc/softirqs --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/timer_list:/proc/timer_list --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/uptime:/proc/uptime --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/vmallocinfo:/proc/vmallocinfo --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/vmstat:/proc/vmstat --mount=\$CONTAINER_DIR/usr/local/etc/tmoe-linux/proot_proc/zoneinfo:/proc/zoneinfo /usr/bin/env -i HOSTNAME=TINY HOME=/home/tiny USER=tiny TERM=xterm-256color SDL_IM_MODULE=fcitx XMODIFIERS=@im=fcitx QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx TMOE_CHROOT=false TMOE_PROOT=true TMPDIR=/tmp MOZ_FAKE_NO_SANDBOX=1 DISPLAY=:4 PULSE_SERVER=tcp:127.0.0.1:4718 LANG=zh_CN.UTF-8 SHELL=/bin/bash PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games /bin/bash -l",
"vnc":"startnovnc &",
"vncUrl":"http://localhost:36082/vnc.html?host=localhost&port=36082&autoconnect=true&resize=remote&password=12345678",
"commands":[{"name":"检查更新并升级", "command":"sudo apt update && sudo apt upgrade -y"},
{"name":"查看系统信息", "command":"neofetch -L && neofetch --off"},
{"name":"清屏", "command":"clear"},
{"name":"安装图形处理软件Krita", "command":"sudo apt update && sudo apt install -y krita krita-l10n"},
{"name":"卸载图形处理软件Krita", "command":"sudo apt autoremove --purge -y krita krita-l10n"},
{"name":"安装视频剪辑软件Kdenlive", "command":"sudo apt update && sudo apt install -y kdenlive"},
{"name":"卸载视频剪辑软件Kdenlive", "command":"sudo apt autoremove --purge -y kdenlive"},
{"name":"安装科学计算软件Octave", "command":"sudo apt update && sudo apt install -y octave"},
{"name":"卸载科学计算软件Octave", "command":"sudo apt autoremove --purge -y octave"},
{"name":"安装WPS", "command":"wget https://wps-linux-personal.wpscdn.cn/wps/download/ep/Linux2019/11704/wps-office_11.1.0.11704_arm64.deb -O /tmp/wps.deb && sudo apt update && sudo apt install -y /tmp/wps.deb; rm /tmp/wps.deb"},
{"name":"卸载WPS", "command":"sudo apt autoremove --purge -y wps-office"},
{"name":"安装CAJViewer", "command":"wget https://download.cnki.net/net.cnki.cajviewer_1.3.20-1_arm64.deb -O /tmp/caj.deb && sudo apt update && sudo apt install -y /tmp/caj.deb && bash /home/tiny/.local/share/tiny/caj/postinst; rm /tmp/caj.deb"},
{"name":"卸载CAJViewer", "command":"sudo apt autoremove --purge -y net.cnki.cajviewer && bash /home/tiny/.local/share/tiny/caj/postrm"},
{"name":"安装亿图图示", "command":"wget https://www.edrawsoft.cn/2download/aarch64/edrawmax_11.5.6-3_arm64.deb -O /tmp/edraw.deb && sudo apt update && sudo apt install -y /tmp/edraw.deb && bash /home/tiny/.local/share/tiny/edraw/postinst; rm /tmp/edraw.deb"},
{"name":"卸载亿图图示", "command":"sudo apt autoremove --purge -y edrawmax libldap-2.4-2"},
{"name":"修复无法编译C语言程序", "command":"sudo apt update && sudo apt reinstall -y libc6-dev"},
{"name":"启用回收站", "command":"sudo apt update && sudo apt install -y gvfs && echo '安装完成, 重启软件即可使用回收站。'"},
{"name":"???", "command":"timeout 8 cmatrix"}]
}"""]);
    await G.prefs.setStringList("adsBonus", []);
    await G.prefs.setInt("adsWatchedTotal", 0);
    await G.prefs.setBool("isTerminalCommandsEnabled", false);
    await G.prefs.setBool("isTerminalWriteEnabled", false);
    await G.prefs.setBool("isBannerAdsClosed", false);
    await G.prefs.setBool("autoLaunchVnc", true);
    await G.prefs.setInt("defaultAudioPort", 4718);
    await G.prefs.setInt("defaultContainer", 0);
    await G.prefs.setInt("termMaxLines", 4095);
    await G.prefs.setDouble("termFontScale", 1);
    await G.prefs.setInt("vip", 0);
    await G.prefs.setBool("isStickyKey", true);
  }

  static Future<void> initData() async {

    G.dataPath = (await getApplicationSupportDirectory()).path;

    G.termPtys = {};

    G.keyboard = VirtualKeyboard(defaultInputHandler);
    
    G.prefs = await SharedPreferences.getInstance();

    //限制一天内观看视频广告不超过5次
    final String currentDate = DateFormat("yyyy-MM-dd").format(DateTime.now());
    if (currentDate != G.prefs.getString("lastDate")) {
      await G.prefs.setString("lastDate", currentDate);
      await G.prefs.setInt("adsWatchedToday", 0);
    }

    //如果没有这个key，说明是初次启动
    if (!G.prefs.containsKey("defaultContainer")) {
      await initForFirstTime();
    }
    G.currentContainer = G.prefs.getInt("defaultContainer")!;

    G.termFontScale = G.prefs.getDouble("termFontScale")!;

    G.controller = WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted);

  }

  static Future<void> initTerminalForCurrent() async {
    if (!G.termPtys.containsKey(G.currentContainer)) {
      G.termPtys[G.currentContainer] = TermPty();
    }
  }

  static Future<void> initAds() async {
    UnityAds.init(
      gameId: AdManager.gameId,
      testMode: false,
      onComplete: () {
        debugPrint('Initialization Complete');
        AdManager.loadAds();
      },
      onFailed: (error, message) => debugPrint('Initialization Failed: $error $message'),
    );
  }

  static Future<void> setupAudio() async {
    G.audioPty?.kill();
    G.audioPty = Pty.start(
      "/system/bin/sh"
    );
    //pulseaudio也需要一个tmp文件夹，这里选择前面的cache，没有什么特别的原因，不行再换
    //pulseaudio还需要一个文件夹放配置，这里用share
    G.audioPty!.write(const Utf8Encoder().convert("""
export DATA_DIR=${G.dataPath}
cd \$DATA_DIR/..
export TMPDIR=\$PWD/cache
cd \$DATA_DIR
export HOME=\$DATA_DIR/share
export LD_LIBRARY_PATH=\$DATA_DIR/bin
\$DATA_DIR/busybox sed "s/4713/${G.prefs.getInt("defaultAudioPort")!}/g" \$DATA_DIR/bin/pulseaudio.conf > \$DATA_DIR/bin/pulseaudio.conf.tmp
\$DATA_DIR/bin/pulseaudio -F \$DATA_DIR/bin/pulseaudio.conf.tmp
exit
"""));
  await G.audioPty?.exitCode;
  }

  static Future<void> launchCurrentContainer() async {
    Util.termWrite(
"""
export DATA_DIR=${G.dataPath}
export CONTAINER_DIR=\$DATA_DIR/containers/${G.currentContainer}
export PROOT_L2S_DIR=\$DATA_DIR/containers/0/.l2s
cd \$DATA_DIR
export PROOT_TMP_DIR=\$DATA_DIR/proot_tmp
export PROOT_LOADER=\$DATA_DIR/libexec/proot/loader
export PROOT_LOADER_32=\$DATA_DIR/libexec/proot/loader32
${Util.getCurrentProp("boot")}
${G.prefs.getBool("autoLaunchVnc")!?Util.getCurrentProp("vnc"):""}
clear""");
  }

  static Future<void> waitForConnection() async {
    await retry(
      // Make a GET request
      () => http.get(Uri.parse(Util.getCurrentProp("vncUrl"))).timeout(const Duration(milliseconds: 250)),
      // Retry on SocketException or TimeoutException
      retryIf: (e) => e is SocketException || e is TimeoutException,
    );
  }

  static Future<void> launchBrowser() async {
    G.controller.loadRequest(Uri.parse(Util.getCurrentProp("vncUrl")));
    Navigator.push(G.homePageStateContext, MaterialPageRoute(builder: (context) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky,overlays: []);
      SystemChrome.setSystemUIChangeCallback((systemOverlaysAreVisible) async {
        await Future.delayed(const Duration(seconds: 1));
        SystemChrome.restoreSystemUIOverlays();
      });
      return Focus(
        onKey: (node, event) {
          // Allow webview to handle cursor keys. Without this, the
          // arrow keys seem to get "eaten" by Flutter and therefore
          // never reach the webview.
          // (https://github.com/flutter/flutter/issues/102505).
          if (!kIsWeb) {
            if ({
              LogicalKeyboardKey.arrowLeft,
              LogicalKeyboardKey.arrowRight,
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.arrowDown
            }.contains(event.logicalKey)) {
              return KeyEventResult.skipRemainingHandlers;
            }
          }
          return KeyEventResult.ignored;
        },
        child: WebViewWidget(controller: G.controller),
      );
    }));
  }

  static Future<void> workflow() async {
    grantPermissions();
    await initData();
    await initAds();
    await initTerminalForCurrent();
    setupAudio();
    launchCurrentContainer();
    if (G.prefs.getBool("autoLaunchVnc")!) {
      waitForConnection().then((value) => launchBrowser());
    }
  }
}


