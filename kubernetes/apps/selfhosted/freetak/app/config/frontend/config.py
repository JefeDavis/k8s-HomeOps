# -*- encoding: utf-8 -*-
"""
License: MIT
Copyright (c) 2019 - present AppSeed.us
"""

import os
from os import environ


class Config(object):
    basedir = os.path.abspath(os.path.dirname(__file__))

    SECRET_KEY = 'key'

    # This will connect to the FTS db
    SQLALCHEMY_DATABASE_URI = 'sqlite:///' + '/home/freetak/data/FTSServer-UI.db'

    # experimental SSL support in the UI

    # certificates path
    # certpath = "/usr/local/lib/python3.8/dist-packages/FreeTAKServer/certs/"

    # crt file path
    # crtfilepath = f"{certpath}pubserver.pem"

    # key file path
    # keyfilepath = f"{certpath}pubserver.key.unencrypted"

    # this IP will be used to connect with the FTS API
    IP = 'freetak-api.internal.davishaus.dev'

    # Port the UI uses to communicate with the API
    PORT = '443'

    # Protocol the UI uses to communicate with the API
    PROTOCOL = 'https'

    # the public IP your server is exposing
    APPIP = '0.0.0.0'

    # webmap IP
    WEBMAPIP = 'node-red.internal.davishaus.dev'

    # webmap port
    WEBMAPPORT = 443

    # webmap protocol
    WEBMAPPROTOCOL = 'https'

    # this port will be used to listen
    APPPort = 5000

    # the webSocket key used by the UI to communicate with FTS.
    WEBSOCKETKEY = 'YourWebsocketKey'

    # the API key used by the UI to comunicate with FTS. generate a new system user and then set it
    APIKEY = 'Bearer token'

    # For 'in memory' database, please use:
    # SQLALCHEMY_DATABASE_URI = 'sqlite:///:memory:'

    SQLALCHEMY_TRACK_MODIFICATIONS = False

    # THEME SUPPORT
    #  if set then url_for('static', filename='', theme='')
    #  will add the theme name to the static URL:
    #    /static/<DEFAULT_THEME>/filename
    # DEFAULT_THEME = "themes/dark"
    DEFAULT_THEME = None


class ProductionConfig(Config):
    DEBUG = False

    # Security
    SESSION_COOKIE_HTTPONLY = True
    REMEMBER_COOKIE_HTTPONLY = True
    REMEMBER_COOKIE_DURATION = 3600

    # PostgreSQL database
    SQLALCHEMY_DATABASE_URI = 'postgresql://{}:{}@{}:{}/{}'.format(
        environ.get('APPSEED_DATABASE_USER', 'appseed'),
        environ.get('APPSEED_DATABASE_PASSWORD', 'appseed'),
        environ.get('APPSEED_DATABASE_HOST', 'db'),
        environ.get('APPSEED_DATABASE_PORT', 5432),
        environ.get('APPSEED_DATABASE_NAME', 'appseed')
    )


class DebugConfig(Config):
    DEBUG = True


config_dict = {
    'Production': ProductionConfig,
    'Debug': DebugConfig
}
