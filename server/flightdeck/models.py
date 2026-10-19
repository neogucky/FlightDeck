from datetime import date
import re
from typing import Annotated
from pydantic import BaseModel, Field, field_validator, model_validator


class LegInput(BaseModel):
    flight_number: str = Field(min_length=3, max_length=10)
    departure_date: date
    origin_iata: str | None = None
    destination_iata: str | None = None

    @field_validator('flight_number')
    @classmethod
    def flight(cls, value):
        value = re.sub(r'\s+', '', value).upper()
        if not re.fullmatch(r'[A-Z0-9]{2,3}[0-9]{1,4}[A-Z]?', value):
            raise ValueError('Use a flight number such as LX1055 or DL47')
        return value

    @field_validator('origin_iata', 'destination_iata')
    @classmethod
    def airport(cls, value):
        if not value or not value.strip():
            return None
        value = value.strip().upper()
        if not re.fullmatch('[A-Z]{3}', value):
            raise ValueError('Airport codes must contain three letters')
        return value

    @model_validator(mode='after')
    def different_airports(self):
        if self.origin_iata and self.origin_iata == self.destination_iata:
            raise ValueError('Departure and arrival airports must differ')
        return self


class TripInput(BaseModel):
    title: str = Field(default='', max_length=80)
    legs: Annotated[list[LegInput], Field(min_length=1, max_length=8)]

    @model_validator(mode='after')
    def connected(self):
        for previous, following in zip(self.legs, self.legs[1:]):
            if previous.departure_date > following.departure_date:
                raise ValueError('Connected flights must be in date order')
            if previous.destination_iata and following.origin_iata and previous.destination_iata != following.origin_iata:
                raise ValueError('Connected flights must share the connecting airport')
        signatures = [(l.flight_number, l.departure_date, l.origin_iata) for l in self.legs]
        if len(signatures) != len(set(signatures)):
            raise ValueError('The same flight cannot be added twice to one trip')
        return self
