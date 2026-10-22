# frozen_string_literal: true

module HotcellRemote
  module Transports
    # Turns a gateway's answer into a Response, or raises: a 4xx is permanent and anything else transient.
    def self.response(status, result_header, content_type, body)
      case status
      when 200
        if content_type == "application/json"
          Response.new(result: JSON.parse(body), output: nil)
        else
          Response.new(result: JSON.parse(result_header), output: body)
        end
      when 400..499 then raise PermanentError, error_message(body)
      else raise TransientError, error_message(body)
      end
    end

    def self.error_message(body)
      JSON.parse(body).fetch("error")
    rescue JSON::ParserError, KeyError, TypeError
      body.to_s[0, 500]
    end
  end
end
