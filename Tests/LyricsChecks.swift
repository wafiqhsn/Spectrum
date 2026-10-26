import Foundation

@main
struct LyricsChecks {
    static func main() {
        let value = LRCParser.parse("""
        [ar:Example]
        [offset:-200]
        [00:10.50]Second line
        [00:02.30][00:05.400]Repeated line
        [00:08.000]
        [00:00:12.75]Hour format
        broken text
        """)
        precondition(value.count == 5)
        precondition(abs(value[0].time - 2.1) < 0.0001)
        precondition(abs(value[1].time - 5.2) < 0.0001)
        precondition(value[0].text == "Repeated line" && value[1].text == "Repeated line")
        precondition(value[2].text.isEmpty)
        precondition(abs(value[4].time - 12.55) < 0.0001)
        precondition(LRCParser.activeIndex(in: value, at: 0) == nil)
        precondition(LRCParser.activeIndex(in: value, at: 7) == 1)
        precondition(LRCParser.activeIndex(in: value, at: 8) == 2)
        precondition(LRCParser.activeIndex(in: value, at: 100) == 4)
        precondition(LRCParser.activeIndex(in: value, at: 3) == 0, "Seeking backwards must update active line")
        precondition(LRCParser.parse("plain untimed lyrics").isEmpty)
        precondition(LRCParser.parse("[00:01.1]a")[0].time == 1.1)
        precondition(LRCParser.parse("[offset:-1000]\n[00:00.50]a")[0].time == 0)
        print("PASS: LRC timestamps, offset, repeats, instrumental gaps, malformed input and forward/backward seek.")
    }
}
