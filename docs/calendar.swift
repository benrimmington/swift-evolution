#!/usr/bin/swift

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// <https://tools.ietf.org/html/rfc5545> Core Object Specification (iCalendar)
// <https://tools.ietf.org/html/rfc7265> jCal: The JSON Format for iCalendar
// <https://tools.ietf.org/html/rfc7986> New Properties for iCalendar
//
//===----------------------------------------------------------------------===//

import Foundation

struct Proposal: Decodable {

  struct Status: Decodable {

    let start: String?
    let end: String?
  }

  let id: String
  let link: String
  let title: String
  let status: Status
}

// MARK: -

extension DateInterval {

  // e.g. "2020-12-31" -> 2020-12-31T00:00:00Z
  static let _proposalDateOnlyFormatter: ISO8601DateFormatter = {
    let result = ISO8601DateFormatter()
    result.formatOptions = [.withFullDate]
    result.timeZone = TimeZone(secondsFromGMT: 0)!
    return result
  }()

  // Accepts any proposal with valid `start` and `end` strings.
  init?(_ proposal: Proposal) {
    guard
      let start = proposal.status.start.flatMap({
        Self._proposalDateOnlyFormatter.date(from: $0)
      }),
      let end = proposal.status.end.flatMap({
        Self._proposalDateOnlyFormatter.date(from: $0)
      }),
      start <= end
    else {
      return nil
    }
    self.init(start: start, end: end)
  }

  // Will be used to trigger a VALARM on the final day.
  var iCalendarDuration: String {
    let days = Calendar.current.dateComponents([.day], from: start, to: end).day
    return "P\(days ?? 0)D"
  }
}

// MARK: -

extension Date {

  // e.g. 2020-12-31T23:59:59Z -> "20201231"
  var iCalendarDateOnly: String {
    ISO8601DateFormatter.string(
      from: self,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      formatOptions: [.withYear, .withMonth, .withDay]
    )
  }

  // e.g. 2020-12-31T23:59:59Z -> "20201231T235959Z"
  var iCalendarDateTimeUTC: String {
    ISO8601DateFormatter.string(
      from: self,
      timeZone: TimeZone(secondsFromGMT: 0)!,
      formatOptions: [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
    )
  }
}

// MARK: -

extension StringProtocol {

  // BACKSLASH, SEMICOLON, COMMA, and LINE FEED (LF) must be escaped.
  var iCalendarEscaped: String {
    self
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: ";", with: "\\;")
      .replacingOccurrences(of: ",", with: "\\,")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  // Content lines of more than 75 bytes should be "folded" with CRLF + HTAB.
  // FIXME: Use the UTF-8 view?
  var iCalendarFolded: String {
    var lines: [Self.SubSequence] = []
    var input: Self.SubSequence = self[...]
    while !input.isEmpty {
      let maxLength = 72 // i.e. Excluding the leading HTAB and trailing CRLF.
      lines.append(input.prefix(maxLength))
      input = input.dropFirst(maxLength)
    }
    // `ICalendar.insert(_:)` will replace the LF with CRLF.
    return lines.joined(separator: "\n\t")
  }
}

// MARK: -

struct ICalendar {

  var _components: [String] = ["BEGIN:VCALENDAR", "END:VCALENDAR"]

  // VCALENDAR must have VERSION and PRODID.
  init() {
    insert(
      """
      VERSION:2.0
      PRODID:B1A7168E-065A-42D1-9E20-31F2E90FBDB1
      X-APPLE-CALENDAR-COLOR:#F05138
      X-WR-CALNAME:Swift Evolution
      NAME:Swift Evolution
      """
    )
  }

  // VEVENT must have UID, DTSTAMP, and DTSTART.
  // VALARM must have ACTION and TRIGGER.
  // `T090000` and `PT0S` are at 9 a.m. in local "floating" time.
  mutating func insert(_ proposal: Proposal) {
    guard let dateInterval = DateInterval(proposal) else {
      return
    }
    insert(
      """
      BEGIN:VEVENT
      UID:B1A7168E-065A-42D1-9E20-31F2E90FBDB1-\(proposal.id)
      DTSTAMP:\(Date().iCalendarDateTimeUTC)
      SUMMARY:\(proposal.id):\u{20}
      \t\(proposal.title.iCalendarEscaped.iCalendarFolded)
      URL:https://github.com/apple/swift-evolution/blob/main/proposals/
      \t\(proposal.link.iCalendarFolded)
      DTSTART:\(dateInterval.start.iCalendarDateOnly)T090000
      TRANSP:TRANSPARENT
      BEGIN:VALARM
      ACTION:AUDIO
      TRIGGER:PT0S
      END:VALARM
      BEGIN:VALARM
      ACTION:AUDIO
      TRIGGER:\(dateInterval.iCalendarDuration)
      END:VALARM
      END:VEVENT
      """
    )
  }

  // iCalendar uses CRLF line breaks.
  // Precondition: `iCalendarEscaped` TEXT property values.
  mutating func insert(_ component: String) {
    let component = component
      .split(separator: "\n", omittingEmptySubsequences: false)
      .joined(separator: "\r\n")
    _components.insert(component, at: _components.endIndex - 1)
  }
}

extension ICalendar: CustomStringConvertible {

  var description: String {
    _components.joined(separator: "\r\n")
  }
}

extension ICalendar: CustomDebugStringConvertible {

  var debugDescription: String {
    _components.joined(separator: "\r\n\r\n")
  }
}

// MARK: -

// A remote or local copy of the JSON data can be used.
let jsonURL: URL
switch (CommandLine.arguments.count, CommandLine.arguments.last) {
case (1, _):
  jsonURL = URL(string: "https://data.swift.org/swift-evolution/proposals")!
case (2, let path?) where !path.hasPrefix("-"):
  jsonURL = URL(fileURLWithPath: path)
default:
  fputs("Usage: \(CommandLine.arguments[0]) [proposals.json]\n", stderr)
  exit(EXIT_FAILURE)
}

// If an error is thrown, print an empty VCALENDAR to stdout.
do {
  var iCalendar = ICalendar()
  defer {
    print(iCalendar, terminator: "\r\n")
  }
  let jsonData = try Data(contentsOf: jsonURL)
  let jsonDecoder = JSONDecoder()
  let proposals = try jsonDecoder.decode([Proposal].self, from: jsonData)
  for proposal in proposals {
    iCalendar.insert(proposal)
  }
} catch {
  fputs("Error: \(error.localizedDescription)\n", stderr)
  exit(EXIT_FAILURE)
}
