/// 南大专属登录配置，取代原来运行时拉取的多学校 `schoolList.json`。
///
/// 抓取管线本身沿用 [ImportFromBEView]（WebView 里跑远程 extractJS，
/// 返回标准化 JSON），这里只是把南大这两组"教务系统"入口的 URL
/// 本地固定下来，不再依赖远程学校列表。
class NjuEntryConfig {
  final String pinyin;
  final String pageTitle;
  final String initialUrl;
  final String redirectUrl;
  final String targetUrl;
  final String extractJSfileAndroid;
  final String extractJSfileiOS;
  final String extractJSfileOHOS;

  const NjuEntryConfig({
    required this.pinyin,
    required this.pageTitle,
    required this.initialUrl,
    required this.redirectUrl,
    required this.targetUrl,
    required this.extractJSfileAndroid,
    required this.extractJSfileiOS,
    required this.extractJSfileOHOS,
  });

  Map<String, dynamic> toConfigMap() => {
        'pinyin': pinyin,
        'page_title': pageTitle,
        'initialUrl': initialUrl,
        'redirectUrl': redirectUrl,
        'targetUrl': targetUrl,
        'preExtractJS': '',
        'delayTime': 3,
        'extractJS': '',
        'extractJSfileAndroid': extractJSfileAndroid,
        'extractJSfileiOS': extractJSfileiOS,
        'extractJSfileOHOS': extractJSfileOHOS,
      };
}

class NjuConfig {
  static const String _cdnRoot =
      'https://cdn.idealclover.cn/Projects/wheretosleepinnju/production/tools';

  static const undergraduate = NjuEntryConfig(
    pinyin: '1nanjingdaxuebenkejiaowu',
    pageTitle: '本科生教务系统登录',
    initialUrl:
        'https://authserver.nju.edu.cn/authserver/login?service=https%3A%2F%2Fehallapp.nju.edu.cn%2Fjwapp%2Fsys%2Fwdkb%2F*default%2Findex.do%23%2Fxskcb',
    redirectUrl: '',
    targetUrl:
        'https://ehallapp.nju.edu.cn/jwapp/sys/wdkb/*default/index.do#/xskcb',
    extractJSfileAndroid: '$_cdnRoot/njubksjw2.js',
    extractJSfileiOS: '$_cdnRoot/njubksjw2.js',
    extractJSfileOHOS: '$_cdnRoot/njubksjw2.js',
  );

  static const graduate = NjuEntryConfig(
    pinyin: '1nanjingdaxueyanjiujiaowu',
    pageTitle: '研究生教务系统登录',
    initialUrl:
        'https://authserver.nju.edu.cn/authserver/login?service=https%3A%2F%2Fehallapp.nju.edu.cn%2Fgsapp%2Fsys%2Fwdkbapp%2F*default%2Findex.do%23%2Fxskcb',
    redirectUrl: '',
    targetUrl:
        'https://ehallapp.nju.edu.cn/gsapp/sys/wdkbapp/*default/index.do#/xskcb',
    extractJSfileAndroid: '$_cdnRoot/njuyjsjw.js',
    extractJSfileiOS: '$_cdnRoot/njuyjsjw.js',
    extractJSfileOHOS: '$_cdnRoot/njuyjsjw.js',
  );

  /// 登录探测统一走本科生这一组入口；登录成功后如果用户选择"研究生"，
  /// 再把同一个已认证的 WebView 导航到 [graduate]，SSO 会话会被复用。
  static const NjuEntryConfig loginProbe = undergraduate;

  static const Map<String, NjuEntryConfig> byPinyin = {
    '1nanjingdaxuebenkejiaowu': undergraduate,
    '1nanjingdaxueyanjiujiaowu': graduate,
  };

  static NjuEntryConfig? findByPinyin(String? pinyin) {
    if (pinyin == null) return null;
    return byPinyin[pinyin];
  }
}
