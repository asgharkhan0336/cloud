from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from .config import Config

db = SQLAlchemy()

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    
    db.init_app(app)
    
    # Register blueprints
    from .api.network_api import network_bp
    app.register_blueprint(network_bp, url_prefix='/api/v1')
    
    # Create tables
    with app.app_context():
        db.create_all()
    
    return app