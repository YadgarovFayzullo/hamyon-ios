import XCTest

/// Подготовка симулятора к съёмке видео: то, что нельзя сделать командой `simctl`.
final class PromoTests: XCTestCase {
    /// Разрешение на уведомления даётся только нажатием «Разрешить» в системном окне.
    func testAllowNotifications() {
        let app = XCUIApplication()
        app.launchArguments = ["-unlocked", "-seedExpenses", "-requestNotifications"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Разрешить"])).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "Окно с разрешением не появилось")
        allow.tap()
    }
}

extension PromoTests {
    /// Первая страница главного экрана: запуск раннера теста перелистывает на его страницу (вторую).
    /// «Домой» на главном экране возвращает на первую.
    func testHomeScreen() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        sleep(1)
    }

    /// Сцена «пришла SMS», вторая половина: открыть Hamyon → сумма прокручивается → «Операции» → новая операция.
    /// Саму SMS скрипт съёмки уже провёл через `-demoSMS`; здесь — только касания.
    func testSMSScene() {
        testHomeScreen()
        let app = XCUIApplication()
        // Имя в шапке «Обзора» — демо, только на этот запуск (домен аргументов UserDefaults).
        app.launchArguments = ["-unlocked", "-profileName", "Азиз Каримов"]
        app.launch()
        sleep(3)  // сумма месяца прокручивается
        // Вкладка — по месту, а не по названию: язык симулятора может быть любым.
        app.tabBars.buttons.element(boundBy: 1).tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "EVOS")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Нет операции EVOS")
        // Касание ждёт, пока приложение «успокоится» (секунды), — скрипт съёмки вырезает это ожидание.
        row.tap()
        sleep(3)
        print("PROMO_DONE \(Date().timeIntervalSince1970)")
        // Следующий прогон снова начнётся с первой страницы главного экрана.
        testHomeScreen()
    }
}
