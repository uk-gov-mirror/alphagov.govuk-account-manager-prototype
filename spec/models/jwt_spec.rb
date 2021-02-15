RSpec.describe Jwt do
  include ActiveSupport::Testing::TimeHelpers

  let!(:user) { FactoryBot.create(:user) }

  let!(:application) do
    FactoryBot.create(
      :oauth_application,
      name: "name",
      redirect_uri: "http://localhost",
      scopes: %i[test_scope_write],
    )
  end

  context "#jwt_payload" do
    let(:private_key) do
      private_key = OpenSSL::PKey::EC.new "prime256v1"
      private_key.generate_key
    end

    let(:public_key) { OpenSSL::PKey::EC.new private_key }

    let(:application_key) do
      ApplicationKey.create!(
        application_uid: application.uid,
        key_id: SecureRandom.uuid,
        pem: public_key.to_pem,
      )
    end

    let(:jwt_uid) { application.uid }
    let(:jwt_key) { application_key.key_id }
    let(:jwt_scopes) { %i[test_scope_write] }
    let(:jwt_attributes) { { test: "value" } }
    let(:jwt_post_login_oauth) { "#{Rails.application.config.redirect_base_url}/oauth/authorize?some-query-string" }
    let(:jwt_post_register_oauth) { "#{Rails.application.config.redirect_base_url}/oauth/authorize?some-other-query-string" }
    let(:jwt_signing_key) { private_key }

    let(:jwt) do
      payload = {
        uid: jwt_uid,
        key: jwt_key,
        scopes: jwt_scopes,
        attributes: jwt_attributes,
        post_register_oauth: jwt_post_register_oauth,
        post_login_oauth: jwt_post_login_oauth,
      }.compact
      JWT.encode payload.compact, jwt_signing_key, "ES256"
    end

    it "accepts" do
      payload = Jwt.create!(jwt_payload: jwt).jwt_payload.deep_symbolize_keys
      expect(payload).to include(:application, :signing_key, :post_login_oauth, :post_register_oauth, scopes: jwt_scopes.map(&:to_s), attributes: jwt_attributes)
      expect(payload[:post_register_oauth]).to eq(jwt_post_register_oauth.delete_prefix(Rails.application.config.redirect_base_url))
      expect(payload[:post_login_oauth]).to eq(jwt_post_login_oauth.delete_prefix(Rails.application.config.redirect_base_url))
      expect(Doorkeeper::Application.find(payload.dig(:application, :id)).uid).to eq(jwt_uid)
      expect(payload.dig(:signing_key, :pem)).to eq(public_key.to_pem)
    end

    context "the JWT came from the API, with an access token" do
      let(:application_with_token) do
        FactoryBot.create(
          :oauth_application,
          name: "other name",
          redirect_uri: "http://localhost",
          scopes: %i[test_scope_write],
        )
      end

      let(:access_token) { FactoryBot.create(:oauth_access_token, application_id: application_with_token.id) }

      let(:jwt_signing_key) do
        private_key = OpenSSL::PKey::EC.new "prime256v1"
        private_key.generate_key
      end

      it "skips the crypto and takes the uid from the access token, not the JWT" do
        jwt_payload = Jwt.create!(jwt_payload: jwt, application_id_from_token: access_token.application_id).jwt_payload.deep_symbolize_keys
        expect(jwt_payload[:application][:id]).to eq(application_with_token.id)
        expect(jwt_payload[:signing_key]).to be_nil
      end
    end

    context "the JWT is missing a UID" do
      let(:jwt_uid) { nil }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::MissingFieldUid)
      end
    end

    context "the JWT is missing a key ID" do
      let(:jwt_key) { nil }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::MissingFieldKey)
      end
    end

    context "the JWT references a missing application" do
      let(:jwt_uid) { "breadbread" }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::UidNotFound)
      end
    end

    context "the JWT references a missing key" do
      let(:jwt_key) { "breadbread" }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::KeyNotFound)
      end
    end

    context "the JWT has been signed with the wrong key" do
      let(:jwt_signing_key) do
        private_key = OpenSSL::PKey::EC.new "prime256v1"
        private_key.generate_key
      end

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::JWTDecodeError)
      end
    end

    context "the JWT asks for scopes the application doesn't have" do
      let(:jwt_scopes) { %i[account_manager_access] }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::InvalidScopes)
      end
    end

    context "the JWT tries to write to an attribute without requesting the scope" do
      let(:jwt_scopes) { [] }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::InsufficientScopes)
      end
    end

    context "the JWT tries to write to an unknown attribute" do
      let(:jwt_attributes) { { foo: "bar" } }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::InsufficientScopes)
      end
    end

    context "the JWT is missing the post-login redirect" do
      let(:jwt_post_login_oauth) { nil }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::MissingFieldPostLoginOAuth)
      end
    end

    context "the JWT is missing the optional post-register redirect" do
      let(:jwt_post_register_oauth) { nil }

      it "accepts" do
        expect { Jwt.create!(jwt_payload: jwt) }.to_not raise_error
      end
    end

    context "the JWT has a bad redirect" do
      let(:jwt_post_login_oauth) { "https://www.example.com" }

      it "rejects" do
        expect { Jwt.create!(jwt_payload: jwt) }.to raise_error(Jwt::InvalidOAuthRedirect)
      end
    end
  end

  context "#expired" do
    it "doesn't include JWTs attached to a RegistrationState" do
      freeze_time do
        jwt = Jwt.create!(created_at: (Jwt::EXPIRATION_AGE + 1.minute).ago, jwt_payload: "old", skip_parse_jwt_token: true)
        RegistrationState.create!(
          state: :start,
          email: "email@example.com",
          jwt_id: jwt.id,
        )

        expect(Jwt.expired.count).to eq(0)
      end
    end

    it "doesn't include JWTs attached to a LoginState" do
      freeze_time do
        jwt = Jwt.create!(created_at: (Jwt::EXPIRATION_AGE + 1.minute).ago, jwt_payload: "old", skip_parse_jwt_token: true)
        LoginState.create!(
          created_at: Time.zone.now,
          user: user,
          redirect_path: "/",
          jwt_id: jwt.id,
        )

        expect(Jwt.expired.count).to eq(0)
      end
    end
  end
end
