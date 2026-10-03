import SwiftUI
import Charts
import Core

struct UsageCharts:View {
    @Environment(\.colorSchemeContrast) private var contrast
    let snapshot:UsagePresentationSnapshot
    let period:UsagePeriod
    @LPState private var metric="requests"
    @LPState private var selectedDay:Date?
    private func caption(_ day:Date)->String {snapshot.days.first{$0.date==day}?.caption ?? ""}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("请求活动 · 最近 52 周").font(.headline)
            Text("颜色表示每日请求次数；包含失败请求。服务、模型、课件和用途筛选适用。").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHGrid(rows:Array(repeating:GridItem(.fixed(12),spacing:3),count:7),spacing:3) {
                    ForEach(snapshot.days){cell in
                        let day=cell.date;let count=cell.count
                        Button{selectedDay=day}label:{RoundedRectangle(cornerRadius:3).fill(count==0 ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(min(1,0.3+log10(Double(count)+1)/2))).frame(width:12,height:12).overlay{if contrast == .increased {RoundedRectangle(cornerRadius:3).stroke(Color.primary,lineWidth:0.7)}}}
                            .buttonStyle(.plain).help(cell.caption).accessibilityLabel(cell.caption)
                    }
                }.padding(3)
            }.defaultScrollAnchor(.trailing).frame(height:112)
            HStack{Text(snapshot.days.first?.date.formatted(date:.abbreviated,time:.omitted) ?? "");Spacer();Text("今天 · 浅色较少，深色较多")}.font(.caption).foregroundStyle(.secondary)
            if let day=selectedDay {
                Text(caption(day)).font(.caption)
                ScrollView { LazyVStack(alignment:.leading) { ForEach(snapshot.daily[day] ?? []){entry in
                    Text("\(entry.value.date.formatted(date:.omitted,time:.shortened)) · \(entry.lesson) · \(entry.value.model) · \(entry.success.map{$0 ? "成功" : "失败"} ?? "状态未记录") · 输入 \(entry.value.inputTokens.map(String.init) ?? "未知") / 输出 \(entry.value.outputTokens.map(String.init) ?? "未知") tokens · 字符 \(entry.value.meteredCharacters.map(String.init) ?? "未返回")").font(.caption).textSelection(.enabled)
                }
                }}.frame(maxHeight:180)
                Button("收起日期详情"){selectedDay=nil}.font(.caption)
            }
            Picker("用量趋势",selection:$metric){
                Text("请求次数").tag("requests");Text("OpenAI tokens").tag("tokens")
                Text("Azure · 服务确认字符").tag("azure");Text("Azure · 本地估算字符").tag("azure:estimate")
                Text("DeepL · 服务确认字符").tag("deepL");Text("DeepL · 本地估算字符").tag("deepL:estimate")
                Text("Apple · 本机处理字符").tag("apple")
            }
            if snapshot.trends.isEmpty {Text("所选范围暂无用量记录。").foregroundStyle(.secondary)}
            else {
                Chart(snapshot.trends){bucket in BarMark(x:.value("时间",bucket.date),y:.value("用量",bucket.values[metric,default:0])).accessibilityLabel(bucket.date.formatted()).accessibilityValue(String(Int(bucket.values[metric,default:0])))}.chartXScale(range:.plotDimension(startPadding:12,endPadding:12)).frame(height:160)
                Text("\(period.rawValue) · 已知记录合计 \(Int(snapshot.totals[metric,default:0]))；未知用量不计入已知合计。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical,8)
    }
}
