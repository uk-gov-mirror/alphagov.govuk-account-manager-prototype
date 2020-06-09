# GOV.UK Account Manager - Prototype

A Prototype to explore how users might authenticate, authorise their data to be exchanged, be informed of data use and manage their consent for it.

## Developer setup

### Prerequisites
You must have the following installed:
- Docker
- Docker Compose

### First time setup

The app uses `docker-compose` to quickly and easily bring up all required services you will need to develop this app.

This can be started from the root of the repo with:
` docker-compose up`

Keycloak expects to run on it's own namespace of `keycloak:8080`. This is essentially an alias for `localhost`. In order to get this running on Mac/Linux:
- Open up your `/etc/hosts`
- Add the line `127.0.0.1        keycloak`
- Save the file and exit

Navigating to http://keycloak:8080 should now bring up the keycloak admin interface.

You will now need to configure keycloak to match the expectations of the app.
- From the `keycloak:8080` "home page" visit the [admin console](http://keycloak:8080/auth/admin/master/console/)
- Login with the development username and password. (See [docker-compose.yml](/docker-compose.yml)) KEYCLOAK_USER & KEYCLOAK_PASSWORD
- Using the side tab navigate to the clients page
- Enter the edit screen for `admin-cli` and change the following settings:
  - Access type: Change from Public to Confidential
  - Toggle switch: Standard flow to enabled
  - Toggle switch: Service accounts to enabled
  - Toggle switch: Authorisation to enabled
  - Valid redirect URI: Enter "*" and press the plus button at the end of the input
- Save using the submit button at the bottom of the page.

Finally at you will need to update the KEYCLOAK_CLIENT_SECRET to match the one generated by your keycloak instance.
- At the top of the `admin-cli` edit screen navigate to the credentials tab
- Copy the greyed out "Secret" field, or generate a new one
- Replace the value of KEYCLOAK_CLIENT_SECRET in [docker-compose.yml](/docker-compose.yml) with your copied secret
- run `docker-compose restart`
