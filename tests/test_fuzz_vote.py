#!/usr/bin/python
# coding: utf-8
import unittest
import random
import os
import sys
import json
import time
from hypothesis import given, HealthCheck, strategies as st, settings as hypothesis_settings
from distutils.util import strtobool
from util.fake_sent_emails_manager import FakeSentEmailsManager
from util.selenium_tools import wait_for_element_exists, wait_for_an_element_with_partial_link_text_exists, wait_for_element_exists_and_does_not_contain_expected_text
from util.election_testing import console_log, remove_database_folder, initialize_server, wait_a_bit, populate_credential_and_password_for_voters_from_sent_emails, populate_random_votes_for_voters
from test_scenario_2 import BeleniosTestElectionScenario2Base, initialize_browser
import settings

# We use a lower min_size than the real one because otherwise example data elements are way too long to generate
choiceNumberAsStringDataFormat = st.text(alphabet="0123456789", min_size=10, max_size=617) # a number written in a text string. Number has between 616 and 617 digits (should probably not start with a 0)
proofNumberAsStringDataFormat = st.text(alphabet="0123456789", min_size=10, max_size=78) # a number written in a text string. Number has between 77 and 78 digits (should probably not start with a 0)

letters_and_digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
electionHashDataFormat = st.text(alphabet=letters_and_digits, min_size=43, max_size=43)
electionIdDataFormat = st.text(alphabet=letters_and_digits, min_size=14, max_size=14)

choiceDataFormat = st.fixed_dictionaries(
    {
        "alpha": choiceNumberAsStringDataFormat,
        "beta": choiceNumberAsStringDataFormat,
    }
)

proofDataFormat = st.fixed_dictionaries(
    {
        "challenge": proofNumberAsStringDataFormat,
        "response": proofNumberAsStringDataFormat,
    }
)

individualProofDataFormat = st.lists(proofDataFormat, min_size=2, max_size=2) # an array

answerDataFormat = st.fixed_dictionaries(
    {
        "choices": st.lists(choiceDataFormat, min_size=2, max_size=2), # an array
        "individual_proofs": st.lists(individualProofDataFormat, min_size=2, max_size=2), # an array
        "overall_proof": st.lists(proofDataFormat, min_size=2, max_size=2), # an array
    }
) # a JSON object

ballotDataFormat = st.fixed_dictionaries(
    {
        "answers": st.lists(answerDataFormat, min_size=1, max_size=1), # an array
        "election_hash": electionHashDataFormat,
        "election_uuid": electionIdDataFormat,
        "signature": st.fixed_dictionaries(
            {
                "public_key": choiceNumberAsStringDataFormat, # string representation of an integer
                "challenge": proofNumberAsStringDataFormat, # string representation of an integer
                "response": proofNumberAsStringDataFormat, # string representation of an integer
            }
        ), # a JSON object
    }
) # a JSON object


def go_to_election_page(browser, election_id):
    election_page_url = "/".join([settings.SERVER_URL, "elections", election_id, ""])
    browser.get(election_page_url)


def log_in(browser, username, password):
    # She enters her identifier and password and submits the form to log in
    login_form_username_value = username # correct value: settings.ADMINISTRATOR_USERNAME
    login_form_password_value = password # correct value: settings.ADMINISTRATOR_PASSWORD

    login_form_username_css_selector = '#main form input[name=username]'
    login_form_password_css_selector = '#main form input[name=password]'

    login_form_username_element = wait_for_element_exists(browser, login_form_username_css_selector, settings.EXPLICIT_WAIT_TIMEOUT)
    login_form_password_element = wait_for_element_exists(browser, login_form_password_css_selector, settings.EXPLICIT_WAIT_TIMEOUT)

    login_form_username_element.send_keys(login_form_username_value)
    login_form_password_element.send_keys(login_form_password_value)

    wait_a_bit()

    login_form_password_element.submit()

    wait_a_bit()


# This is a Python decorator
def try_n_times(max_attempts):
    def decorator_try_n_times(func):
        def wrapper_try_n_times(*args, **kwargs):
            current_attempt = 0
            while(current_attempt < max_attempts):
                try:
                    return func(*args, current_attempt=current_attempt, **kwargs)
                except Exception as e:
                    console_log("Retrying after exception", e)
                    current_attempt += 1
                    time.sleep(1)
            if current_attempt >= max_attempts:
                raise Exception("Could not locate expected element")
        return wrapper_try_n_times
    return decorator_try_n_times


class BeleniosMonkeyTestFuzzVoteAdvancedMode(BeleniosTestElectionScenario2Base):

    def __init__(self, *args, **kw):
        super().__init__(*args, **kw)
        self.distant_fake_sent_emails_manager = None
        self.fake_sent_emails_initial_lines_count = None


    def setUp(self):
        self.fake_sent_emails_manager = FakeSentEmailsManager(settings.SENT_EMAILS_TEXT_FILE_ABSOLUTE_PATH)
        self.fake_sent_emails_manager.install_fake_sendmail_log_file()
        if settings.START_SERVER:
            remove_database_folder()
            self.server = initialize_server()
        self.browser = initialize_browser()
        if settings.ELECTION_ID:
            self.election_id = settings.ELECTION_ID
        else:
            # Download server's sent emails text file, so that we know up to which line number we have to ignore its contents (this is its last line)
            temporary_fake_sent_emails_manager = None
            try:
                temporary_fake_sent_emails_manager = self.download_all_sent_emails()
                self.fake_sent_emails_initial_lines_count = temporary_fake_sent_emails_manager.count_lines()
                console_log("### Initial lines count of server's fake sent emails file:", self.fake_sent_emails_initial_lines_count)
            finally:
                if temporary_fake_sent_emails_manager:
                    temporary_fake_sent_emails_manager.uninstall_fake_sendmail_log_file()

            self.administrator_creates_election()

            console_log("### Starting step: download_all_sent_emails")
            self.distant_fake_sent_emails_manager = self.download_all_sent_emails()
            console_log("### Step complete: download_all_sent_emails")

            # Concatenate (distant) Belenios server's sent emails file (starting after line `fake_sent_emails_initial_lines_count`) and local credential authority's sent emails file into file `self.distant_fake_sent_emails_manager.log_file_path`, so that `self.generate_vote_ballots()` can parse it and find all information it needs.
            import subprocess
            import tempfile
            (file_handle, log_file_path) = tempfile.mkstemp(text=True)
            with open(log_file_path, 'w') as f:
                subprocess.run(["tail", "-n", "+" + str(self.fake_sent_emails_initial_lines_count + 1), self.distant_fake_sent_emails_manager.log_file_path], stdout=f)
                subprocess.run(["cat", self.fake_sent_emails_manager.log_file_path], stdout=f)
            subprocess.run(["cp", log_file_path, self.distant_fake_sent_emails_manager.log_file_path])
            subprocess.run(["rm", "-f", log_file_path])

            invited_voters_who_will_vote = random.sample(self.voters_email_addresses, settings.NUMBER_OF_VOTING_VOTERS)
            invited_voters_who_will_vote_data = populate_credential_and_password_for_voters_from_sent_emails(self.distant_fake_sent_emails_manager, invited_voters_who_will_vote, settings.ELECTION_TITLE)
            invited_voters_who_will_vote_data = populate_random_votes_for_voters(invited_voters_who_will_vote_data)
            self.update_voters_data(invited_voters_who_will_vote_data)

            settings.VOTER_USERNAME = invited_voters_who_will_vote_data[0]["username"]
            settings.VOTER_PASSWORD = invited_voters_who_will_vote_data[0]["password"]
        console_log("Going to vote as VOTER_USERNAME:", settings.VOTER_USERNAME)
        console_log("Going to vote as VOTER_PASSWORD:", settings.VOTER_PASSWORD)


    def tearDown(self):
        self.browser.quit()
        if settings.START_SERVER:
            self.server.kill()
            remove_database_folder()
        self.fake_sent_emails_manager.uninstall_fake_sendmail_log_file()
        if self.distant_fake_sent_emails_manager is not None:
            self.distant_fake_sent_emails_manager.uninstall_fake_sendmail_log_file()


    def download_all_sent_emails(self, target_fake_sent_emails_manager=None):
        from urllib.parse import urljoin
        import urllib.request
        if not target_fake_sent_emails_manager:
            import tempfile
            (file_handle, log_file_path) = tempfile.mkstemp(text=True)
            target_fake_sent_emails_manager = FakeSentEmailsManager(log_file_path)
        distant_fake_emails_file_url = urljoin(settings.SERVER_URL, settings.FAKE_SENT_EMAILS_FILE_RELATIVE_URL) # TODO: maybe we should build this URL by picking link value in alert banner on distant server home page
        console_log("distant_fake_emails_file_url:", distant_fake_emails_file_url)
        urllib.request.urlretrieve(distant_fake_emails_file_url, target_fake_sent_emails_manager.log_file_path)
        console_log("#### Distant fake sent emails have been saved in:", target_fake_sent_emails_manager.log_file_path)
        return target_fake_sent_emails_manager


    @given(st.text())
    @hypothesis_settings(deadline=None)
    def test_submit_prepared_ballot_by_dumb_monkey(self, ballot):
        self.submit_prepared_ballot(ballot)


    @given(ballotDataFormat)
    @hypothesis_settings(deadline=None, suppress_health_check=[HealthCheck.large_base_example, HealthCheck.data_too_large])
    def test_submit_prepared_ballot_by_smart_monkey_v2(self, ballot):
        try:
            browser = self.browser
            ballot['election_uuid'] = self.election_id
            printable_ballot = json.dumps(ballot)
            console_log("### Starting a new Monkey navigation that will try to submit ballot:", printable_ballot)
            result = self.submit_prepared_ballot(printable_ballot)
            if result:
                console_log("#### Page title was 'Password login', so we log in")
                # Our ballot is not detected as ill-formed, so we arrive on the log in screen
                log_in(browser, settings.VOTER_USERNAME, settings.VOTER_PASSWORD)
                console_log("#### Analyzing page title, expecting it not to be 'Unauthorized'")
                # If user provided a wrong username/password combination, the resulting page is a browser error page like `<h1>Unauthorized</h1><p>Error 401</p>`
                page_title_css_selector = "h1"
                expected_text_1 = "Password login"
                expected_text_2 = "Unauthorized"
                page_title_element = wait_for_element_exists_and_does_not_contain_expected_text(browser, page_title_css_selector, expected_text_1, settings.EXPLICIT_WAIT_TIMEOUT)
                page_title_element = wait_for_element_exists_and_does_not_contain_expected_text(browser, page_title_css_selector, expected_text_2, settings.EXPLICIT_WAIT_TIMEOUT)
                page_title_label = page_title_element.get_attribute('innerText')
                assert page_title_label != expected_text_1
                assert page_title_label != expected_text_2
                console_log("#### Page title was not 'Unauthorized', so we click on confirm ballot submission button")
                # We arrive on the next screen, which asks us to confirm ballot submission
                submit_button_css_selector = "input[type=submit]"
                submit_button_element = wait_for_element_exists(browser, submit_button_css_selector, settings.EXPLICIT_WAIT_TIMEOUT)
                submit_button_element.click()

                # We check wether the ballot has been received and parsed without errors
                @try_n_times(5)
                def verify_step_label(browser, current_attempt=0):
                    console_log("#### Analyzing (attempt", current_attempt, ") whether result page (after click on confirm ballot submission button) has as step title 'Step 6/6: FAIL!' because ballot content is invalid")
                    current_step_css_selector = "#main .current_step"
                    current_step_element = wait_for_element_exists(browser, current_step_css_selector, settings.EXPLICIT_WAIT_TIMEOUT)
                    current_step_label = current_step_element.get_attribute('innerText')
                    console_log("#### Step title is:", current_step_label)
                    if current_step_label == "Step 6/6: FAIL!":
                        console_log("#### Page step title was 'Step 6/6: FAIL!', which is what we expected. So the full test is correct.")
                        return current_step_label
                    else:
                        # TODO: Handle very improbable case where ballot is accepted (for now we would consider that this is a test failure). Maybe also it could be necessary to better detect any case that falls outside these 2 situations.
                        console_log("#### Step title is unexpected. So the full test is incorrect.")
                        raise Exception("Step title is unexpected:", current_step_label)

                final_label = verify_step_label(browser)
                assert final_label == "Step 6/6: FAIL!"
        except Exception as e:
            console_log("Step title is unexpected. Exception received:", e)
            browser.quit()
            self.browser = initialize_browser()
            raise e


    def submit_prepared_ballot(self, ballot):
        browser = self.browser
        console_log("#### Going to election page")
        go_to_election_page(browser, self.election_id)

        console_log("#### Clicking on 'en' language link")
        language_label = "en"
        language_link_element = wait_for_an_element_with_partial_link_text_exists(browser, language_label, settings.EXPLICIT_WAIT_TIMEOUT)
        language_link_element.click()

        console_log("#### Clicking on 'Advanced mode' link")
        partial_link_text = "Advanced mode"
        link_element = wait_for_an_element_with_partial_link_text_exists(browser, partial_link_text, settings.EXPLICIT_WAIT_TIMEOUT)
        link_element.click()

        console_log("#### Filling ballot field with text representation of ballot and clicking on Submit button")
        field_css_selector = "form[action=submit-ballot] textarea[name=encrypted_vote]"
        field_element = wait_for_element_exists(browser, field_css_selector, settings.EXPLICIT_WAIT_TIMEOUT)
        field_element.clear()
        field_element.send_keys(ballot)
        field_element.submit()

        wait_a_bit()

        @try_n_times(5)
        def verify_page_title(browser, current_attempt):
            console_log("#### Analyzing (attempt", current_attempt, ") contents of page returned after having clicked on Submit button, expecting title to be either 'Ill-formed ballot' or 'Password login'")
            page_title_css_selector = "#header h1"
            page_title_element = wait_for_element_exists(browser, page_title_css_selector)
            page_title_label = page_title_element.get_attribute('innerText') # Here we sometimes get a stale element. This is why we run this inside a loop with several attempts

            page_content_css_selector = "#main"
            page_content_element = wait_for_element_exists(browser, page_content_css_selector)
            page_content_label = page_content_element.get_attribute('innerText')

            console_log("#### Page title was", page_title_label, "and page content was", page_content_label)
            if page_title_label == "Error":
                assert page_content_label == "Ill-formed ballot"
                return page_title_label
            elif page_title_label == "Password login":
                return page_title_label
            else:
                # This case happens sometimes, because Selenium has not yet replaced its DOM with the new DOM of the page (maybe because server has not responded yet or page loading is not yet complete).
                # In this situation, data is still: ('Unexpected page content', 'USERNAME:\t\nPASSWORD:\t')
                # Or: ('Unexpected page content', 'My test election for Scenario 1', 'Username:Password:')
                raise Exception("Unexpected page content", page_title_label, page_content_label)

        try:
            page_title = verify_page_title(browser)
            assert page_title in ["Error", "Password login"]
            return page_title
        except Exception as e:
            console_log("Could not locate expected element. Exception received:", e)
            # browser.quit()
            # self.browser = initialize_browser()
            raise e


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

    settings.ELECTION_ID = os.getenv('ELECTION_ID', None) or None
    settings.VOTER_USERNAME = os.getenv('VOTER_USERNAME', None) or None
    settings.VOTER_PASSWORD = os.getenv('VOTER_PASSWORD', None) or None
    settings.FAKE_SENT_EMAILS_FILE_RELATIVE_URL = os.getenv('FAKE_SENT_EMAILS_FILE_RELATIVE_URL', "static/mail.txt")

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
