import AppKit
import SwiftUI

/// 「この操作は何をするのか」への短い答え。作った人ではなく、使う人に向けて書く。
struct HelpView: View {
    private struct Topic: Identifiable {
        let id = UUID()
        let title: String
        let points: [String]
    }

    private let topics: [Topic] = [
        Topic(title: "表示", points: [
            "pptx を開くと、そのまま描いて表示します。PowerPoint は要りません。描画はアプリの中で完結し、外部へは一切通信しません。",
            "← → PageUp PageDown Space でスライドを移動します。左の一覧をクリックしても移動できます。",
            "⌘+ と ⌘- で拡大・縮小、⌘0 でウインドウに合わせます。拡大していると、描き直しても倍率と位置を保ちます。",
            "⌘F で本文とノートを検索します。⌘G で次、⇧⌘G で前の該当スライドへ。大文字小文字、全角半角は区別しません。",
            "⇧⌘↩ でスライドショー。全画面で 1 枚ずつ出し、Esc で戻ります。ショーの最中に書き換わっても描き直します。",
        ]),
        Topic(title: "更新", points: [
            "開いているファイルを別のアプリが書き換えると、自動で描き直します。上書き保存でも、一時ファイルからの置き換えでも拾います。",
            "見ていたスライド番号はそのまま保ちます。スライドが減ってそのページが無くなったときは、最後のスライドを出します。",
            "直前の更新で変わったスライドには、一覧の番号の下にオレンジの丸が付きます。",
            "⌘B で、見ているスライドの前の版と今の版を切り替えます。前の版の上には帯が出ます。",
            "後ろに回しているときに更新されると、Dock のアイコンが一度跳ねます。",
        ]),
        Topic(title: "メモ（フィードバック）", points: [
            "ノートの右のメモ欄に、そのスライドへのメモを書けます。書いたスライドには、一覧に吹き出しが付きます。",
            "⌥⌘C で、メモをスライド番号と見出しつきでまとめてコピーします。そのまま Claude などに貼れます。",
            "メモはファイルごとに保存されます。消すときは「編集 > このファイルのメモをすべて消す…」。",
        ]),
        Topic(title: "コピーと書き出し", points: [
            "一覧で ⌘C、または右クリックで、そのスライドを画像としてコピーします。⇧⌘C は見ているスライド。3840×2160 の PNG です。",
            "「ファイル > 書き出す」で、PDF か画像（PNG）の束に書き出せます。非表示スライドは除きます。",
            "「このスライドだけを pptx で…」は、描画がおかしいときの報告用です。ほかのスライドの文字や画像は入りません。",
        ]),
        Topic(title: "Claude との連携（MCP）", points: [
            "アプリに MCP サーバーが入っています。Claude Code に一度登録すると、Claude がこのビューアを直接使えます。登録は「Proofdeck > Claude Code と連携する…」から。登録済みならメニューにチェックが付きます。",
            "Claude ができること: いま見ているスライドを知る、スライドを画像で受け取って見た目を確かめる、文字のはみ出しや重なりを測る、直前の更新で変わったスライドを知る、メモを読んで済にする、スライドへ移る、資料を開く。",
            "Claude が生成している間は、下に青い帯「Claude が生成中…」が出て、途中の版を描き直しません。書き終わると一度だけ描き直します。",
            "Claude が済にしたメモは、一覧の吹き出しが緑の印に変わります。メモを書き直すと、印は外れます。",
            "ビューアが閉じていても、Claude が使うときに裏で立ち上がります。",
        ]),
        Topic(title: "一覧とノート", points: [
            "左の一覧は番号つきのサムネイルです。非表示スライドは薄く、番号に打ち消し線がつきます。幅は好きなだけ広げられ、広げると鮮明に撮り直します。",
            "⌥⌘N でノートとメモの欄を隠したり出したりできます。境目はドラッグで動かせます。",
        ]),
        Topic(title: "ウインドウ", points: [
            "ウインドウの位置と大きさ、見ていたスライドは、ファイルごとに覚えます。",
            "ファイルを指定せずに起動すると、前回開いていたファイルを開き直します。無ければ最後に使ったファイル、それも無ければファイルの選択画面を出します。",
        ]),
        Topic(title: "うまくいかないとき", points: [
            "「描画できませんでした」と出るときは、ファイルが壊れていないか、書き込みが終わっているかを確かめてください。表示は前回の内容のまま残ります。",
            "描画が PowerPoint と違って見えるときは、「このスライドだけを pptx で…」で書き出したファイルを添えて Issue で教えてください。",
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            topicList
        }
        // 大きさは読む人が決める。読み物のウインドウなので、伸び縮みできるようにしておく
        .frame(minWidth: 360, idealWidth: 460, maxWidth: .infinity,
               minHeight: 320, idealHeight: 560, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: AppIconImage.full)
                .resizable()
                .frame(width: 72, height: 72)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Proofdeck")
                .font(.title3.weight(.semibold))
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var topicList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(topic.title).font(.headline)
                        ForEach(topic.points, id: \.self) { point in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(point).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// ヘルプのウインドウは一つだけ。閉じても捨てず、次に開くときに同じものを出す
@MainActor
enum HelpWindow {
    private static var controller: NSWindowController?

    static func show() {
        if controller == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
            window.title = "Proofdeck ヘルプ"
            window.styleMask = [.titled, .closable, .resizable]
            window.setFrameAutosaveName("Proofdeck.Help")
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
