require "erb"

module Zendesk
  class Ticket
    def initialize(contact)
      @contact = HashWithIndifferentAccess.new(contact)
    end

    def attributes
      {
        "subject" => @contact[:subject],
        "requester" => { "locale_id" => 1, "email" => @contact[:email] },
        "comment" => { "body" => rendered_body },
      }
    end

  private

    def rendered_body
      path_to_template = Rails.root.join("app/zendesk/contact.erb")
      template = ERB.new(File.read(path_to_template))
      template.result(binding)
    end
  end
end
