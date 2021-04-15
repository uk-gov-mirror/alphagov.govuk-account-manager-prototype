require 'faker'

if Rails.env.development?
  2500.times do
    created_at = time_rand
    current_sign_in = time_rand(created_at)

    User.create!(
      email: Faker::Internet.email,
      phone: Faker::PhoneNumber.cell_phone,
      created_at: created_at,
      last_sign_in_at: time_rand(created_at, current_sign_in),
      current_sign_in_at: current_sign_in,
      last_mfa_success: current_sign_in,
      password: Faker::Internet.password(min_length: 10, max_length: 20, mix_case: true),
      has_received_onboarding_email: true,
      has_received_2021_03_survey: rand > 0.4,
      banned_password_match: false,
      cookie_consent: rand < 0.77,
      feedback_consent: rand < 0.68,
    )
  end
end



def time_rand(from = 1601903320.0, to = Time.now)
  Time.zone.at(from + rand * (to.to_f - from.to_f))
end
