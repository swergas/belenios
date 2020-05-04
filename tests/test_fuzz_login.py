#!/usr/bin/python
# coding: utf-8
import unittest
import random
import os
import sys
from hypothesis import given
import hypothesis.strategies as st
from hypothesis import settings as hypothesis_settings
from distutils.util import strtobool
from util.fake_sent_emails_manager import FakeSentEmailsManager
from util.election_testing import console_log, remove_database_folder, wait_a_bit, initialize_server
from util.page_objects import ServerHomePage, VoterLoginPage, UnauthorizedPage, AdministrationHomeLoggedInPage
from test_scenario_2 import BeleniosTestElectionScenario2Base, initialize_browser_for_scenario_2
import settings


def get_browser_page_content(browser):
    """
    Returns something like: b'<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" lang="fr" prefix="og: http://ogp.me/ns#"><head>\n        \n        <meta charset="utf-8" />'
    """

    return browser.page_source.encode("utf-8")


def go_to_log_in_page(browser):
    # Alice has been given administrator rights on an online voting app called Belenios. She goes
    # to check out its homepage

    timeout = settings.EXPLICIT_WAIT_TIMEOUT
    browser.get(settings.SERVER_URL)

    wait_a_bit()

    # She verifies she is on the server home page
    server_home_page = ServerHomePage(browser, timeout)
    server_home_page.verify_page()

    # If a personal data policy modal appears (it does not appear after it has been accepted), she clicks on the "Accept" button
    server_home_page.click_on_accept_button_in_personal_data_policy_modal_if_available()

    # She clicks on "local" to go to the login page
    server_home_page.click_on_login_link(settings.LOGIN_MODE)

    wait_a_bit()


class BeleniosMonkeyTestFuzzLogin(BeleniosTestElectionScenario2Base):

    def __init__(self, *args, **kw):
        super().__init__(*args, **kw)


    def setUp(self):
        self.fake_sent_emails_manager = FakeSentEmailsManager(settings.SENT_EMAILS_TEXT_FILE_ABSOLUTE_PATH)
        self.fake_sent_emails_manager.install_fake_sendmail_log_file()
        if settings.START_SERVER:
            remove_database_folder()
            self.server = initialize_server()
        self.browser = initialize_browser_for_scenario_2()


    def tearDown(self):
        self.browser.quit()
        if settings.START_SERVER:
            self.server.kill()
            remove_database_folder()
        self.fake_sent_emails_manager.uninstall_fake_sendmail_log_file()


    @given(st.text(), st.text())
    @hypothesis_settings(deadline=None)
    def test_log_in(self, username, password):
        browser = self.browser
        timeout = settings.EXPLICIT_WAIT_TIMEOUT
        go_to_log_in_page(browser)
        login_page = VoterLoginPage(browser, timeout)
        login_page.verify_page()
        login_page.log_in(username, password)

        try:
            unauthorized_page = UnauthorizedPage(browser, timeout)
            unauthorized_page.verify_page()
        except Exception:
            administration_page = AdministrationHomeLoggedInPage(browser, timeout)
            administration_page.verify_page()
            console_log(f"### Warning: Submitting random input (\"{username}\", \"{password}\") to log in form directs to administration logged in page.") # Or should we rather re-raise an exception because it is very unlikely?


if __name__ == "__main__":
    if not hasattr(settings, "LOGIN_MODE"):
        settings.LOGIN_MODE = "local"
    if not hasattr(settings, "START_SERVER"):
        settings.START_SERVER = True

    random_seed = os.getenv('RANDOM_SEED', None)
    if not random_seed:
        random_seed = random.randrange(sys.maxsize)
    console_log("Python random seed being used:", random_seed)
    random.seed(random_seed)

    settings.SERVER_URL = os.getenv('SERVER_URL', settings.SERVER_URL)
    if os.getenv('START_SERVER', None):
        settings.START_SERVER = bool(strtobool(os.getenv('START_SERVER')))

    if os.getenv('USE_HEADLESS_BROWSER', None):
        settings.USE_HEADLESS_BROWSER = bool(strtobool(os.getenv('USE_HEADLESS_BROWSER')))

    settings.SENT_EMAILS_TEXT_FILE_ABSOLUTE_PATH = os.getenv('SENT_EMAILS_TEXT_FILE_ABSOLUTE_PATH', settings.SENT_EMAILS_TEXT_FILE_ABSOLUTE_PATH)
    settings.WAIT_TIME_BETWEEN_EACH_STEP = float(os.getenv('WAIT_TIME_BETWEEN_EACH_STEP', settings.WAIT_TIME_BETWEEN_EACH_STEP)) # Do not set a value below 0.02 seconds, otherwise hypothesis test becomes flaky.
    settings.EXPLICIT_WAIT_TIMEOUT = int(os.getenv('EXPLICIT_WAIT_TIMEOUT', settings.EXPLICIT_WAIT_TIMEOUT))
    settings.NUMBER_OF_INVITED_VOTERS = int(os.getenv('NUMBER_OF_INVITED_VOTERS', settings.NUMBER_OF_INVITED_VOTERS))
    settings.NUMBER_OF_VOTING_VOTERS = int(os.getenv('NUMBER_OF_VOTING_VOTERS', settings.NUMBER_OF_VOTING_VOTERS))
    settings.NUMBER_OF_REVOTING_VOTERS = int(os.getenv('NUMBER_OF_REVOTING_VOTERS', settings.NUMBER_OF_REVOTING_VOTERS))
    settings.NUMBER_OF_REGENERATED_PASSWORD_VOTERS = int(os.getenv('NUMBER_OF_REGENERATED_PASSWORD_VOTERS', settings.NUMBER_OF_REGENERATED_PASSWORD_VOTERS))
    settings.LOGIN_MODE = os.getenv('LOGIN_MODE', settings.LOGIN_MODE)
    settings.ADMINISTRATOR_USERNAME = os.getenv('ADMINISTRATOR_USERNAME', settings.ADMINISTRATOR_USERNAME)
    settings.ADMINISTRATOR_PASSWORD = os.getenv('ADMINISTRATOR_PASSWORD', settings.ADMINISTRATOR_PASSWORD)
    settings.ELECTION_TITLE = os.getenv('ELECTION_TITLE', settings.ELECTION_TITLE)
    settings.ELECTION_DESCRIPTION = os.getenv('ELECTION_DESCRIPTION', settings.ELECTION_DESCRIPTION)

    console_log("SERVER_URL:", settings.SERVER_URL)
    console_log("START_SERVER:", settings.START_SERVER)
    console_log("USE_HEADLESS_BROWSER:", settings.USE_HEADLESS_BROWSER)
    console_log("SENT_EMAILS_TEXT_FILE_ABSOLUTE_PATH:", settings.SENT_EMAILS_TEXT_FILE_ABSOLUTE_PATH)
    console_log("WAIT_TIME_BETWEEN_EACH_STEP:", settings.WAIT_TIME_BETWEEN_EACH_STEP)
    console_log("EXPLICIT_WAIT_TIMEOUT:", settings.EXPLICIT_WAIT_TIMEOUT)
    console_log("NUMBER_OF_INVITED_VOTERS:", settings.NUMBER_OF_INVITED_VOTERS)
    console_log("NUMBER_OF_VOTING_VOTERS:", settings.NUMBER_OF_VOTING_VOTERS)
    console_log("NUMBER_OF_REVOTING_VOTERS:", settings.NUMBER_OF_REVOTING_VOTERS)
    console_log("NUMBER_OF_REGENERATED_PASSWORD_VOTERS:", settings.NUMBER_OF_REGENERATED_PASSWORD_VOTERS)
    console_log("LOGIN_MODE:", settings.LOGIN_MODE)
    console_log("ELECTION_TITLE:", settings.ELECTION_TITLE)
    console_log("ELECTION_DESCRIPTION:", settings.ELECTION_DESCRIPTION)

    unittest.main()
