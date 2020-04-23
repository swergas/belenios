#!/usr/bin/python
# coding: utf-8
from selenium.webdriver.common.alert import Alert
from util.selenium_tools import find_visible_element_which_contains_expected_text, wait_for_element_exists, wait_for_an_element_with_link_text_exists, wait_for_element_exists_and_contains_expected_text, wait_for_element_exists_and_has_non_empty_content, find_visible_element_and_attribute_contains_expected_text
from util.election_testing import wait_a_bit
from util.execution import console_log


class SeleniumPageObjectModel():
    """
    Classes which inherit from SeleniumPageObjectModel are meant to follow the "Page Object" design pattern of Selenium, as described here: https://www.selenium.dev/documentation/en/guidelines_and_recommendations/page_object_models/
    """
    def __init__(self, browser, timeout):
        self.browser = browser
        self.timeout = timeout


class VerifiablePage(SeleniumPageObjectModel):
    def verify_page(self):
        pass


class VoterLoginPage(VerifiablePage):
    login_form_username_css_selector = '#main form input[name=username]'
    login_form_password_css_selector = '#main form input[name=password]'


    def verify_page(self):
        find_visible_element_which_contains_expected_text(self.browser, "h1", "Password login", self.timeout)


    def log_in(self, username, password):
        # She enters her identifier and password and submits the form to log in
        login_form_username_value = username # correct value: settings.ADMINISTRATOR_USERNAME
        login_form_password_value = password # correct value: settings.ADMINISTRATOR_PASSWORD

        login_form_username_element = wait_for_element_exists(self.browser, self.login_form_username_css_selector, self.timeout)
        login_form_password_element = wait_for_element_exists(self.browser, self.login_form_password_css_selector, self.timeout)

        login_form_username_element.send_keys(login_form_username_value)
        login_form_password_element.send_keys(login_form_password_value)

        wait_a_bit()

        login_form_password_element.submit()

        wait_a_bit()


class ElectionHomePage(VerifiablePage):
    def click_on_language_link(self, language_link_label):
        language_link_element = wait_for_an_element_with_link_text_exists(self.browser, language_link_label, self.timeout)
        language_link_element.click()


    def click_on_start_button(self):
        start_button_label = "Start"
        start_button_css_selector = "#main button"
        start_button_element = wait_for_element_exists_and_contains_expected_text(self.browser, start_button_css_selector, start_button_label, self.timeout)
        start_button_element.click()

    # TODO: verify_page, click_on_advanced_mode_link, click_on_see_accepted_ballots_link, etc.


class NormalVoteGenericStepPage(VerifiablePage):
    current_step_css_selector = ".current_step"
    expected_step_content = "Step"


    def verify_step_title(self):
        console_log(f"**Verifying that current step contains '{self.expected_step_content}")
        find_visible_element_which_contains_expected_text(self.browser, self.current_step_css_selector, self.expected_step_content, self.timeout)


    def verify_page(self):
        self.verify_step_title()


class NormalVoteStep1Page(NormalVoteGenericStepPage):
    expected_step_content = "Step 1/6: Input credential"


    def click_on_here_button_and_type_voter_credential(self, voter_credential):
        here_button_label = "here"
        here_button_css_selector = "#main button"
        here_button_element = wait_for_element_exists_and_contains_expected_text(self.browser, here_button_css_selector, here_button_label, self.timeout)
        here_button_element.click()

        wait_a_bit()

        # A modal opens (it is an HTML modal created using Window.prompt()), with an input field. He types his credential.
        credential_prompt = Alert(self.browser)
        credential_prompt.send_keys(voter_credential)
        credential_prompt.accept()


class NormalVoteStep2Page(NormalVoteGenericStepPage):
    expected_step_content = "Step 2/6: Answer to questions"


    def click_on_next_button(self):
        step_2_parent_css_selector = "#question_div"
        next_button = find_visible_element_which_contains_expected_text(self.browser, step_2_parent_css_selector + " button", "Next", self.timeout)
        next_button.click()


class NormalVoteGenericStepWithBallotTrackerPage(NormalVoteGenericStepPage):
    def get_smart_ballot_tracker_value(self):
        smart_ballot_tracker_css_selector = "#ballot_tracker"
        smart_ballot_tracker_element = wait_for_element_exists_and_has_non_empty_content(self.browser, smart_ballot_tracker_css_selector, self.timeout)
        smart_ballot_tracker_value = smart_ballot_tracker_element.get_attribute('innerText')
        return smart_ballot_tracker_value


    def verify_ballot_tracker_value(self):
        smart_ballot_tracker_value = self.get_smart_ballot_tracker_value()
        assert len(smart_ballot_tracker_value) > 5


class NormalVoteStep3Page(NormalVoteGenericStepWithBallotTrackerPage):
    expected_step_content = "Step 3/6: Review and encrypt"


    def verify_page_body(self):
        step_3_parent_css_selector = "#ballot_div"
        step_3_expected_success_content = "Your ballot has been successfully encrypted"
        find_visible_element_which_contains_expected_text(self.browser, step_3_parent_css_selector, step_3_expected_success_content, self.timeout)
        self.verify_ballot_tracker_value()


    def verify_page(self):
        NormalVoteGenericStepWithBallotTrackerPage.verify_page(self)
        self.verify_page_body()


    def click_on_continue_button(self):
        continue_button = find_visible_element_and_attribute_contains_expected_text(self.browser, "input[type=submit]", "value", "Continue", self.timeout)
        continue_button.click()

    # TODO: click_on_restart_button


class NormalVoteStep5Page(NormalVoteGenericStepWithBallotTrackerPage):
    expected_step_content = "Step 5/6: Confirm"


    def verify_page_body(self, expected_ballot_tracker, expected_username):
        step_5_parent_css_selector = "#main"
        step_5_expected_success_content = "has been received, but not recorded yet"
        find_visible_element_which_contains_expected_text(self.browser, step_5_parent_css_selector, step_5_expected_success_content, self.timeout)
        self.verify_ballot_tracker_value()
        ballot_tracker_value = self.get_smart_ballot_tracker_value()
        assert ballot_tracker_value == expected_ballot_tracker

        find_visible_element_which_contains_expected_text(self.browser, step_5_parent_css_selector, expected_username, self.timeout)


    def verify_page(self, expected_ballot_tracker, expected_username):
        NormalVoteGenericStepWithBallotTrackerPage.verify_page(self)
        self.verify_page_body(expected_ballot_tracker, expected_username)


    def click_on_i_cast_my_vote_button(self):
        i_cast_my_vote_button_label = "I cast my vote"
        i_cast_my_vote_button_element = find_visible_element_and_attribute_contains_expected_text(self.browser, "input[type=submit]", "value", i_cast_my_vote_button_label, self.timeout)
        i_cast_my_vote_button_element.click()

    # TODO: click_on_go_back_to_election_link


class NormalVoteStep6Page(NormalVoteGenericStepWithBallotTrackerPage):
    expected_step_content = "Step 6/6: Thank you for voting!"


    def verify_page_body(self, expected_ballot_tracker):
        step_6_parent_css_selector = "#main"
        expected_step_6_body_content = "has been accepted"
        find_visible_element_which_contains_expected_text(self.browser, step_6_parent_css_selector, expected_step_6_body_content, self.timeout)
        self.verify_ballot_tracker_value()
        ballot_tracker_value = self.get_smart_ballot_tracker_value()
        assert ballot_tracker_value == expected_ballot_tracker


    def verify_page(self, expected_ballot_tracker):
        NormalVoteGenericStepWithBallotTrackerPage.verify_page(self)
        self.verify_page_body(expected_ballot_tracker)


    def click_on_ballot_box_link(self):
        ballot_box_label = "ballot box"
        ballot_box_link_element = wait_for_an_element_with_link_text_exists(self.browser, ballot_box_label)
        ballot_box_link_element.click()

    # TODO: click_on_go_back_to_election_link
