/// 南大专属登录配置，取代原来运行时拉取的多学校 `schoolList.json`。
///
/// 这里只负责把南大两组"教务系统"入口的 URL 本地固定下来；抓取由
/// `NjuEhallJsonImporter` 完成——在已登录的 WebView 内直接请求 eHall 的
/// 内部 JSON 接口，不再走上游那套"按学校下发远程 extractJS 脚本"的路径。
class NjuEntryConfig {
  final String pinyin;
  final String pageTitle;
  final String initialUrl;
  final String redirectUrl;
  final String targetUrl;

  const NjuEntryConfig({
    required this.pinyin,
    required this.pageTitle,
    required this.initialUrl,
    required this.redirectUrl,
    required this.targetUrl,
  });
}

class NjuConfig {
  static const undergraduate = NjuEntryConfig(
    pinyin: '1nanjingdaxuebenkejiaowu',
    pageTitle: '本科生教务系统登录',
    initialUrl:
        'https://authserver.nju.edu.cn/authserver/login?service=https%3A%2F%2Fehallapp.nju.edu.cn%2Fjwapp%2Fsys%2Fwdkb%2F*default%2Findex.do%23%2Fxskcb',
    redirectUrl: '',
    targetUrl:
        'https://ehallapp.nju.edu.cn/jwapp/sys/wdkb/*default/index.do#/xskcb',
  );

  static const graduate = NjuEntryConfig(
    pinyin: '1nanjingdaxueyanjiujiaowu',
    pageTitle: '研究生教务系统登录',
    initialUrl:
        'https://authserver.nju.edu.cn/authserver/login?service=https%3A%2F%2Fehallapp.nju.edu.cn%2Fgsapp%2Fsys%2Fwdkbapp%2F*default%2Findex.do%23%2Fxskcb',
    redirectUrl: '',
    targetUrl:
        'https://ehallapp.nju.edu.cn/gsapp/sys/wdkbapp/*default/index.do#/xskcb',
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
