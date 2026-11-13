import XCTest
@testable import ImmichSwiftUI

/// The date-only wire format of a person's birthday (gap G15, AC-5150).
///
/// The failure this file guards against is a one-day drift: the repo's
/// timestamp formatters (`JSONCoding`, `LongDateFormatter`) parse ISO-8601
/// instants, and reusing one of them for a `format: date` value shifts the day
/// in every time zone whose offset is not zero. Nothing else in the feature can
/// be wrong in a way a hundred other tests would not catch.
final class PersonBirthdayTests: XCTestCase {

    func test_wireRoundTrip_isIdentity() throws {
        // `"2000-01-01"` is the trap: it is exactly midnight local, so a parser
        // that drops or adds a UTC offset lands on 1999-12-31.
        for wire in ["1990-05-12", "2000-01-01", "2024-12-31"] {
            let date = try XCTUnwrap(PersonBirthday.date(from: wire), "\(wire) did not parse")
            XCTAssertEqual(PersonBirthday.wire(from: date), wire)
        }
    }

    func test_parse_rejectsMalformed() {
        XCTAssertNil(PersonBirthday.date(from: nil))
        for wire in [
            "",
            "12/05/1990",
            "1990-13-01",
            "1990-02-30",
            "1990-5-12",
            "1990-05-12T00:00:00.000Z",
        ] {
            XCTAssertNil(PersonBirthday.date(from: wire), "\(wire) should not parse")
        }
    }

    func test_display_isNilForNilAndMalformed() {
        XCTAssertNil(PersonBirthday.display(nil))
        XCTAssertNil(PersonBirthday.display(""))
        XCTAssertNil(PersonBirthday.display("1990-02-30"))
    }

    func test_display_isNonEmptyForValidWire() {
        XCTAssertFalse(PersonBirthday.display("1990-05-12")?.isEmpty ?? true)
    }

    // MARK: - CalendarDay and PersonAge (L-24)

    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    func test_day_acceptsOnlyStrictDates() {
        XCTAssertEqual(PersonBirthday.day(from: "2000-06-15"), CalendarDay(year: 2000, month: 6, day: 15))
        XCTAssertEqual(PersonBirthday.day(from: "2000-02-29"), CalendarDay(year: 2000, month: 2, day: 29))
        XCTAssertNil(PersonBirthday.day(from: nil))
        for wire in ["", "12/05/1990", "1990-13-01", "1990-02-30", "1990-5-12", "1900-02-29",
                     "1990-05-12T00:00:00.000Z"] {
            XCTAssertNil(PersonBirthday.day(from: wire), "\(wire) should not parse")
        }
    }

    func test_day_doesNotDependOnTheDeviceTimeZone() throws {
        for id in ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: id))
            XCTAssertEqual(PersonBirthday.day(from: "2000-01-01"), CalendarDay(year: 2000, month: 1, day: 1), id)
            XCTAssertEqual(PersonBirthday.day(from: "2024-12-31"), CalendarDay(year: 2024, month: 12, day: 31), id)
        }
    }

    func test_AC_220_ageFormulaBoundaries() {
        let birth = CalendarDay(year: 2000, month: 6, day: 15)
        XCTAssertEqual(PersonAge.at(birth: birth, on: CalendarDay(year: 2020, month: 6, day: 14)), .years(19))
        XCTAssertEqual(PersonAge.at(birth: birth, on: CalendarDay(year: 2020, month: 6, day: 15)), .years(20))
        XCTAssertNil(PersonAge.at(birth: birth, on: CalendarDay(year: 1999, month: 12, day: 1)))
        XCTAssertEqual(PersonAge.at(birth: birth, on: birth), .months(0))
        XCTAssertNil(PersonAge.at(birth: birth, on: CalendarDay(year: 2000, month: 6, day: 14)))

        let baby = CalendarDay(year: 2024, month: 1, day: 10)
        XCTAssertEqual(PersonAge.at(birth: baby, on: CalendarDay(year: 2024, month: 2, day: 12)), .months(1))
        XCTAssertEqual(PersonAge.at(birth: baby, on: CalendarDay(year: 2024, month: 4, day: 20)), .months(3))
        XCTAssertEqual(PersonAge.at(birth: baby, on: CalendarDay(year: 2025, month: 1, day: 10)), .years(1))
        XCTAssertEqual(PersonAge.at(birth: baby, on: CalendarDay(year: 2025, month: 3, day: 20)), .oneYearAnd(months: 2))
        XCTAssertEqual(PersonAge.at(birth: baby, on: CalendarDay(year: 2026, month: 2, day: 1)), .years(2))

        let leap = CalendarDay(year: 2000, month: 2, day: 29)
        XCTAssertEqual(PersonAge.at(birth: leap, on: CalendarDay(year: 2001, month: 2, day: 28)), .months(11))
    }

    func test_AC_221_frenchLabelsForEachForm() throws {
        let (bundle, locale) = try language("fr")
        XCTAssertEqual(PersonAge.months(1).label(bundle: bundle, locale: locale), "1 mois")
        XCTAssertEqual(PersonAge.months(3).label(bundle: bundle, locale: locale), "3 mois")
        XCTAssertEqual(PersonAge.years(1).label(bundle: bundle, locale: locale), "1 an")
        XCTAssertEqual(PersonAge.oneYearAnd(months: 2).label(bundle: bundle, locale: locale), "1 an et 2 mois")
        XCTAssertEqual(PersonAge.years(2).label(bundle: bundle, locale: locale), "2 ans")
        XCTAssertEqual(PersonAge.years(19).label(bundle: bundle, locale: locale), "19 ans")
    }

    func test_AC_221_everyLanguageAgreesTheFormWithTheCount() throws {
        let expected: [String: [String]] = [
            "de": ["1 Monat alt", "3 Monate alt", "1 Jahr und 1 Monat alt", "1 Jahr und 2 Monate alt", "1 Jahr alt", "2 Jahre alt"],
            "es": ["1 mes", "3 meses", "1 año y 1 mes", "1 año y 2 meses", "1 año", "2 años"],
            "it": ["1 mese", "3 mesi", "1 anno e 1 mese", "1 anno e 2 mesi", "1 anno", "2 anni"],
        ]
        let ages: [PersonAge] = [
            .months(1), .months(3), .oneYearAnd(months: 1), .oneYearAnd(months: 2), .years(1), .years(2),
        ]
        for (code, labels) in expected {
            let (bundle, locale) = try language(code)
            XCTAssertEqual(ages.map { $0.label(bundle: bundle, locale: locale) }, labels, code)
        }
    }
}
