class DeviseRegistrationController < Devise::RegistrationsController
  include CookiesHelper

  # rubocop:disable Rails/LexicallyScopedActionFilter
  prepend_before_action :authenticate_scope!, only: %i[edit_password edit_email update destroy]
  prepend_before_action :set_minimum_password_length, only: %i[new edit_password edit_email]
  # rubocop:enable Rails/LexicallyScopedActionFilter

  before_action :check_registration_state, only: %i[
    phone_code
    phone_verify
    phone_resend
    phone_resend_code
    your_information
    your_information_post
    transition_emails
    transition_emails_post
    create
  ]

  def start
    render :closed and return unless Rails.configuration.enable_registration

    payload = get_payload

    @criteria_keys = payload.dig(:attributes, :transition_checker_state, "criteria_keys") if payload

    return if request.get?

    resource_params = sign_up_params(params)
    self.resource = User.new(resource_params)
    resource.errors.add :email, :taken if User.exists?(email: resource_params[:email])

    if resource.valid?
      state = MultiFactorAuth.is_enabled? ? :phone : :your_information
      RegistrationState.transaction do
        destroy_stale_states(session[:jwt_id]) if session[:jwt_id]
        @registration_state = RegistrationState.create!(
          touched_at: Time.zone.now,
          state: state,
          previous_url: payload&.dig(:post_register_oauth).presence || params[:previous_url],
          jwt_id: session[:jwt_id],
          **resource_params.except(:password_confirmation),
        )
        MultiFactorAuth.generate_and_send_code(@registration_state) if MultiFactorAuth.is_enabled?
      end
      session[:registration_state_id] = @registration_state.id
      redirect_to url_for_state
    end
  end

  def phone_code
    redirect_to url_for_state and return unless registration_state.state == "phone"
  end

  def phone_verify
    redirect_to url_for_state and return unless registration_state.state == "phone"

    state = MultiFactorAuth.verify_code(registration_state, params[:phone_code])
    if state == :ok
      registration_state.update!(state: :your_information)
      redirect_to new_user_registration_your_information_path
    else
      @phone_code_error_message = I18n.t("mfa.errors.phone_code.#{state}", resend_link: new_user_registration_phone_resend_path)
      render :phone_code
    end
  end

  def phone_resend
    redirect_to url_for_state and return unless registration_state.state == "phone"

    @phone = MultiFactorAuth.e164_number(params[:phone] || registration_state.phone)
  end

  def phone_resend_code
    redirect_to url_for_state and return unless registration_state.state == "phone"

    @phone = MultiFactorAuth.e164_number(params[:phone] || registration_state.phone)

    unless MultiFactorAuth.valid?(@phone.presence)
      @phone_error_message = I18n.t("activerecord.errors.models.user.attributes.phone.invalid")
      return
    end

    registration_state.transaction do
      registration_state.update!(phone: @phone)
      MultiFactorAuth.generate_and_send_code(registration_state)
    end

    redirect_to new_user_registration_phone_code_path
  end

  def your_information
    redirect_to url_for_state unless registration_state.state == "your_information"
    @consents = {}
  end

  def your_information_post
    redirect_to url_for_state and return unless registration_state.state == "your_information"

    cookie_consent_decision = params.dig(:cookie_consent)
    cookie_consent_decision_format_ok = %w[yes no].include? cookie_consent_decision

    feedback_consent_decision = params.dig(:feedback_consent)
    feedback_consent_decision_format_ok = %w[yes no].include? feedback_consent_decision

    @error_items = []
    @consents = {}

    if cookie_consent_decision_format_ok
      registration_state.update!(cookie_consent: cookie_consent_decision == "yes")
      @consents[:cookie_consent_decision] = cookie_consent_decision
    else
      @error_items << { field: "cookie_consent", href: "#cookie_consent", text: I18n.t("activerecord.errors.models.user.attributes.cookie_consent_decision.invalid") }
    end

    if feedback_consent_decision_format_ok
      registration_state.update!(feedback_consent: feedback_consent_decision == "yes")
      @consents[:feedback_consent_decision] = feedback_consent_decision
    else
      @error_items << { field: "feedback_consent", href: "#feedback_consent", text: I18n.t("activerecord.errors.models.user.attributes.feedback_consent_decision.invalid") }
    end

    if !registration_state.cookie_consent.nil? && !registration_state.feedback_consent.nil?
      cookies[:cookies_preferences_set] = "true"
      response["Set-Cookie"] = cookies_policy_header(registration_state)

      email_topic_slug = registration_state.jwt_payload&.dig("attributes", "transition_checker_state", "email_topic_slug")
      if email_topic_slug
        registration_state.update!(state: :transition_emails)
        redirect_to new_user_registration_transition_emails_path
      else
        redirect_to new_user_registration_finish_path
      end
      return
    end

    render :your_information
  end

  def transition_emails
    redirect_to url_for_state unless registration_state.state == "transition_emails"
  end

  def transition_emails_post
    redirect_to url_for_state and return unless registration_state.state == "transition_emails"

    decision = params.dig(:email_decision)
    decision_format_ok = %w[yes no].include? decision
    if decision_format_ok
      registration_state.update!(
        state: :finish,
        yes_to_emails: decision == "yes",
      )
      redirect_to new_user_registration_finish_path
      return
    end

    @resource_error_messages = {
      email_decision: [
        I18n.t("activerecord.errors.models.user.attributes.email_decision.invalid"),
      ],
    }
    render :transition_emails
  end

  def create
    super do |resource|
      next unless resource.persisted?

      persist_attributes(resource)
      persist_email_subscription(resource)

      @previous_url = registration_state.previous_url
      registration_state.destroy!
      session.delete(:registration_state_id)

      session[:confirmations] = {
        email: resource.email,
        user_is_confirmed: false,
        user_is_new: true,
      }

      record_security_event(SecurityActivity::USER_CREATED, user: resource)
    end
    flash.clear
  end

  # from https://github.com/heartcombo/devise/blob/f5cc775a5feea51355036175994edbcb5e6af13c/app/controllers/devise/registrations_controller.rb#L46
  def update
    self.resource = resource_class.to_adapter.get!(send(:"current_#{resource_name}").to_key)
    prev_unconfirmed_email = resource.unconfirmed_email if resource.respond_to?(:unconfirmed_email)

    old_email = resource.email

    new_email = params.dig(:user, :email)
    new_password = params.dig(:user, :password)

    if new_email && new_email == resource.email
      redirect_to edit_user_registration_email_path, flash: { alert: I18n.t("devise.failure.same_email") }
      return
    end

    resource_updated = update_resource(resource, account_update_params)
    yield resource if block_given?

    # 'resource_updated' is true if the new email address and new
    # password are both blank, even though no change has been made; so
    # manually handle this case, rather than tell users we've changed
    # their password even when nothing has happened.
    if new_password && new_password.blank?
      resource_updated = false
      resource.errors.add(:password, :new_blank)
    end

    if resource_updated
      record_security_event(SecurityActivity::EMAIL_CHANGE_REQUESTED, user: resource, notes: "from #{old_email} to #{new_email}") if new_email
      record_security_event(SecurityActivity::PASSWORD_CHANGED, user: resource) if new_password

      resource.update!(banned_password_match: false) if new_password

      set_flash_message_for_update(resource, prev_unconfirmed_email)
      bypass_sign_in resource, scope: resource_name if sign_in_after_change_password?

      if new_email
        UserMailer.with(user: resource, new_address: new_email).changing_email_email.deliver_later
        session[:confirmations] = {
          email: new_email,
          user_is_confirmed: resource.confirmed?,
        }
        respond_with resource, location: confirmation_email_sent_path
      else
        flash[:notice] = I18n.t("devise.registrations.edit.success")
        redirect_to :user_root
      end
    else
      clean_up_passwords resource
      set_minimum_password_length
      if new_email
        render :edit_email
      else
        render :edit_password
      end
    end
  end

  def cancel
    registration_state&.destroy!
    super
  end

  def edit_email; end

  def edit_password; end

protected

  def after_sign_up_path_for(_resource)
    confirmation_email_sent_path(previous_url: @previous_url)
  end

  def after_inactive_sign_up_path_for(resource)
    after_sign_up_path_for(resource)
  end

  def check_registration_state
    @registration_state_id = session[:registration_state_id]
    redirect_to new_user_registration_start_path unless registration_state
  end

  # used in the 'super' of 'create'
  def respond_with(resource, *args, location: nil, **kwargs)
    if location
      redirect_to location
    else
      super(resource, *args, **kwargs)
    end
  end

  # used in the 'super' of 'create'
  def sign_up_params(params = nil)
    if params
      sign_up_params = {
        email: params.dig(:user, :email),
        password: params.dig(:user, :password),
        password_confirmation: params.dig(:user, :password),
      }
      sign_up_params[:phone] = params.dig(:user, :phone) if MultiFactorAuth.is_enabled?
    else
      sign_up_params = {
        email: registration_state.email,
        password: registration_state.password,
        password_confirmation: registration_state.password,
        cookie_consent: registration_state.cookie_consent,
        feedback_consent: registration_state.feedback_consent,
        banned_password_match: false,
      }

      if registration_state.phone
        sign_up_params[:phone] = registration_state.phone
        sign_up_params[:last_mfa_success] = Time.zone.now
      end
    end

    sign_up_params
  end

  def registration_state
    @registration_state ||=
      begin
        RegistrationState.find(@registration_state_id).tap do |state|
          state.update!(touched_at: Time.zone.now)
        end
      rescue ActiveRecord::RecordNotFound
        session.delete(:registration_state_id)
        nil
      end
  end

  def url_for_state
    case registration_state.state
    when "phone"
      new_user_registration_phone_code_path
    when "your_information"
      new_user_registration_your_information_path
    when "transition_emails"
      new_user_registration_transition_emails_path
    when "finish"
      new_user_registration_finish_path
    else
      new_user_registration_start_path
    end
  end

  def persist_attributes(user)
    return unless registration_state.jwt_payload
    return if registration_state.jwt_payload["scopes"].empty?

    token = Doorkeeper::AccessToken.create!(
      resource_owner_id: user.id,
      application_id: registration_state.jwt_payload["application"]["id"],
      expires_in: Doorkeeper.config.access_token_expires_in,
      scopes: registration_state.jwt_payload["scopes"],
    )

    SetAttributesJob.perform_later(token.id, registration_state.jwt_payload["attributes"])
  end

  def persist_email_subscription(user)
    return unless registration_state.jwt_payload
    return unless registration_state.yes_to_emails

    email_topic_slug = registration_state.jwt_payload.dig("attributes", "transition_checker_state", "email_topic_slug")
    return unless email_topic_slug

    EmailSubscription.create!(user_id: user.id, topic_slug: email_topic_slug)
  end
end
