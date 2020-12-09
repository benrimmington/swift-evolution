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

    let state: String
    let start: String?
    let end: String?

    var isReview: Bool {
      state == ".scheduledForReview" || state == ".activeReview"
    }
  }

  let id: String
  let link: String
  let title: String
  let status: Status
}

// MARK: -

extension ISO8601DateFormatter {

  // e.g. "2020-12-31T09:00:00" -> 2020-12-31T17:00:00Z (9 a.m. Pacific Time).
  static let withPacificTimeZone: ISO8601DateFormatter = {
    let result = ISO8601DateFormatter()
    result.formatOptions.subtract([.withTimeZone])
    result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return result
  }()

  // e.g. 2020-12-31T17:00:00Z -> "20201231T170000Z" (iCalendar DATE-TIME).
  static let withoutSeparators: ISO8601DateFormatter = {
    let result = ISO8601DateFormatter()
    result.formatOptions.subtract([
      .withDashSeparatorInDate,
      .withColonSeparatorInTime,
      .withColonSeparatorInTimeZone,
    ])
    return result
  }()
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
      PRODID:\(UUID().uuidString)
      X-APPLE-CALENDAR-COLOR:#F05138
      X-WR-CALNAME:Swift Evolution
      NAME:Swift Evolution
      """
    )
  }

  // VEVENT must have UID, DTSTAMP, and DTSTART.
  // VALARM must have ACTION and TRIGGER.
  mutating func insert(_ proposal: Proposal) {
    guard
      proposal.status.isReview,
      let start: Date = proposal.status.start.flatMap({
        ISO8601DateFormatter.withPacificTimeZone.date(from: $0 + "T09:00:00")
      })
    else {
      return
    }
    insert(
      """
      BEGIN:VEVENT
      UID:\(UUID().uuidString)
      DTSTAMP:\(ISO8601DateFormatter.withoutSeparators.string(from: Date()))
      SUMMARY:\(proposal.id):\u{20}
      \t\(proposal.title.iCalendarEscaped.iCalendarFolded)
      URL:https://github.com/apple/swift-evolution/blob/main/proposals/
      \t\(proposal.link.iCalendarFolded)
      DTSTART:\(ISO8601DateFormatter.withoutSeparators.string(from: start))
      TRANSP:TRANSPARENT
      BEGIN:VALARM
      ACTION:AUDIO
      TRIGGER:PT0S
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
